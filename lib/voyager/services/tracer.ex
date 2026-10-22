defmodule Voyager.Services.Tracer do
  @moduledoc """
  Owns the active tracing session of this Voyager instance; the UI and MCP both go through it.

  A session is created, configured, then switched on and off with `start/1` and
  `stop/1`; starting a stopped session resumes it. The tracer on the remote node
  pushes event batches straight to this process.

  A session is a log of entries numbered by `seq`: `:configured`, `:started`,
  `:stopped`, `:trace` (a trace event) and `:dropped` (how many events were lost
  since the previous entry). The configured, started and stopped entries and the
  newest trace and dropped entries are kept in memory. Broadcasts on `topic/0` are
  `{:session_created, session}`, `{:session_closed, id}` and
  `{:session_log, session, entries}` with the entries just appended, oldest first.
  """

  use GenServer

  alias Voyager.Agent
  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Session

  @topic "tracing"
  @kept_events 500
  @max_mailbox 1_000
  @call_timeout Agent.default_timeout() + 1_000

  @type origin :: :ui | :mcp

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Replaces the active session with a new, unconfigured one. Returns `{:error, :busy}` while it runs."
  @spec create(origin(), save: boolean()) :: {:ok, Session.t()} | {:error, :busy}
  def create(origin, opts \\ []) when origin in [:ui, :mcp],
    do: GenServer.call(__MODULE__, {:create, origin, Keyword.get(opts, :save, false)})

  @doc "Closes the active session. Returns `{:error, :busy}` while it runs."
  @spec close() :: :ok | {:error, :busy}
  def close, do: GenServer.call(__MODULE__, :close)

  @doc """
  Sets the active session to trace `node` with `attrs` (see `Config`).
  Selected pids are resolved on `node` in the caller. Returns `{:error, :busy}` while it runs.
  """
  @spec configure(node(), map(), origin()) ::
          {:ok, Session.t()} | {:error, :no_session | :busy | Ecto.Changeset.t() | term()}
  def configure(node, attrs, origin) when origin in [:ui, :mcp] do
    with {:ok, config} <- attrs |> Config.changeset() |> Ecto.Changeset.apply_action(:validate),
         {:ok, pids} <- resolve_pids(node, config) do
      GenServer.call(
        __MODULE__,
        {:configure, node, config, Config.to_agent(config, pids), origin}
      )
    end
  end

  @doc "Starts or resumes the configured session; the agent's refusals come back as `{:error, reason}`."
  @spec start(origin()) :: {:ok, Session.t()} | {:error, term()}
  def start(origin) when origin in [:ui, :mcp],
    do: GenServer.call(__MODULE__, {:start, origin}, @call_timeout)

  @doc """
  Asks the remote tracer to stop; a `:stopped` entry with reason `:stopped` follows.
  Stops any session, whoever started it.
  """
  @spec stop(origin()) :: :ok
  def stop(origin) when origin in [:ui, :mcp],
    do: GenServer.call(__MODULE__, {:stop, origin}, @call_timeout)

  @doc """
  Ends a running session with `:disconnected` once its tracer goes down, without calling the node.
  The remote tracer stops by itself when this node disconnects.
  """
  @spec disconnected() :: :ok
  def disconnected, do: GenServer.cast(__MODULE__, :disconnected)

  @doc "The active session and its kept entries, newest first."
  @spec active() :: {Session.t() | nil, [map()]}
  def active, do: GenServer.call(__MODULE__, :active)

  @impl true
  def init(nil),
    do: {:ok, %{session: nil, agent_args: nil, log: [], events: [], run: nil}}

  @impl true
  def handle_call(request, _from, %{session: %Session{status: :running}} = state)
      when request == :close or
             (is_tuple(request) and elem(request, 0) in [:create, :configure, :start]),
      do: {:reply, {:error, :busy}, state}

  def handle_call({:create, origin, save}, _from, state) do
    session = %Session{
      id: System.unique_integer([:positive]),
      origin: origin,
      save: save,
      created_at: DateTime.utc_now()
    }

    broadcast({:session_created, session})
    {:reply, {:ok, session}, %{state | session: session, agent_args: nil, log: [], events: []}}
  end

  def handle_call(:close, _from, %{session: nil} = state), do: {:reply, :ok, state}

  def handle_call(:close, _from, %{session: session} = state) do
    broadcast({:session_closed, session.id})
    {:reply, :ok, %{state | session: nil, agent_args: nil, log: [], events: []}}
  end

  def handle_call(request, _from, %{session: nil} = state)
      when elem(request, 0) in [:configure, :start],
      do: {:reply, {:error, :no_session}, state}

  def handle_call({:configure, node, config, agent_args, origin}, _from, state) do
    state =
      %{state | session: %{state.session | node: node, config: config}, agent_args: agent_args}
      |> append([control(:configured, origin, node: node, config: config)])

    {:reply, {:ok, state.session}, state}
  end

  def handle_call({:start, _origin}, _from, %{session: %Session{config: nil}} = state),
    do: {:reply, {:error, :not_configured}, state}

  def handle_call({:start, origin}, _from, %{session: session} = state) do
    {spec, limits} = state.agent_args

    case Agent.call(session.node, :trace_start, [self(), spec, limits], Agent.default_timeout()) do
      {:ok, {:ok, tracer}} ->
        Process.monitor(tracer)

        session = %{
          session
          | tracer: tracer,
            status: :running,
            stop_reason: nil,
            started_at: session.started_at || DateTime.utc_now(),
            ended_at: nil
        }

        Voyager.Telemetry.dispatch!("voyager.trace.start",
          metadata:
            session.config
            |> Map.take([:capture, :scope, :return_trace, :processes])
            |> Map.put(:origin, origin)
        )

        run = %{
          origin: origin,
          events: session.events,
          dropped: session.dropped,
          dropped_here: 0,
          stopping: nil,
          at: System.monotonic_time()
        }

        state = append(%{state | session: session, run: run}, [control(:started, origin)])
        {:reply, {:ok, state.session}, state}

      {:ok, {:error, reason}} ->
        start_failed(reason, origin, state)

      {:error, reason} ->
        start_failed(reason, origin, state)
    end
  end

  # The session ends on the tracer's done message or its DOWN, never on this reply.
  def handle_call({:stop, origin}, _from, %{session: %{status: :running} = session} = state) do
    Agent.call(session.node, :trace_stop, [session.tracer], Agent.default_timeout())
    {:reply, :ok, %{state | run: %{state.run | stopping: {:stopped, origin}}}}
  end

  def handle_call({:stop, _origin}, _from, state), do: {:reply, :ok, state}

  def handle_call(:active, _from, state),
    do: {:reply, {state.session, Enum.sort_by(state.log ++ state.events, & &1.seq, :desc)}, state}

  @impl true
  def handle_cast(:disconnected, %{session: %{status: :running}} = state),
    do: {:noreply, %{state | run: %{state.run | stopping: {:disconnected, nil}}}}

  def handle_cast(:disconnected, state), do: {:noreply, state}

  @impl true
  def handle_info(
        {:voyager_trace_events, tracer, events, agent_dropped},
        %{session: %{tracer: tracer, status: :running} = session, run: run} = state
      ) do
    {events, dropped_here} =
      if overloaded?(),
        do: {[], run.dropped_here + length(events)},
        else: {events, run.dropped_here}

    dropped = run.dropped + agent_dropped + dropped_here

    session = %{session | events: session.events + length(events), dropped: dropped}

    state =
      %{state | session: session, run: %{run | dropped_here: dropped_here}}
      |> append(
        dropped_entry(dropped - state.session.dropped) ++
          Enum.map(events, &Map.put(&1, :kind, :trace))
      )

    {:noreply, state}
  end

  def handle_info(
        {:voyager_trace_done, tracer, reason, %{dropped: dropped}},
        %{session: %{tracer: tracer, status: :running}} = state
      ) do
    {:noreply, finish(state, reason, state.run.dropped + dropped + state.run.dropped_here)}
  end

  def handle_info(
        {:DOWN, _ref, :process, tracer, reason},
        %{session: %{tracer: tracer, status: :running} = session} = state
      ) do
    {:noreply, finish(state, down_reason(reason), session.dropped)}
  end

  def handle_info(_stale, state), do: {:noreply, state}

  defp finish(%{run: run} = state, reason, dropped) do
    {reason, origin} = run.stopping || {reason, nil}

    session = %{
      state.session
      | status: :stopped,
        stop_reason: reason,
        dropped: dropped,
        ended_at: DateTime.utc_now()
    }

    run_events = session.events - run.events
    run_dropped = session.dropped - run.dropped

    Voyager.Telemetry.dispatch!("voyager.trace.stop",
      measurements: %{
        events: run_events,
        dropped: run_dropped,
        duration_ms:
          System.convert_time_unit(System.monotonic_time() - run.at, :native, :millisecond)
      },
      metadata: %{origin: run.origin, reason: reason}
    )

    append(
      %{state | session: session, run: nil},
      dropped_entry(session.dropped - state.session.dropped) ++
        [control(:stopped, origin, reason: reason, events: run_events, dropped: run_dropped)]
    )
  end

  defp start_failed(reason, origin, state) do
    Voyager.Telemetry.dispatch!("voyager.trace.start_failed",
      metadata: %{origin: origin, reason: reason}
    )

    {:reply, {:error, reason}, state}
  end

  defp control(kind, origin, fields \\ []),
    do:
      Map.merge(%{kind: kind, origin: origin, at: System.os_time(:microsecond)}, Map.new(fields))

  defp dropped_entry(0), do: []
  defp dropped_entry(count), do: [control(:dropped, nil, count: count)]

  # Dropped entries come with every shed batch, so they are capped with the trace events.
  defp append(%{session: session} = state, entries) do
    entries = Enum.with_index(entries, &Map.put(&1, :seq, session.seq + &2))
    session = %{session | seq: session.seq + length(entries)}
    {traces, controls} = Enum.split_with(entries, &(&1.kind in [:trace, :dropped]))

    broadcast({:session_log, session, entries})

    %{
      state
      | session: session,
        log: Enum.reverse(controls) ++ state.log,
        events: Enum.take(Enum.reverse(traces) ++ state.events, @kept_events)
    }
  end

  defp resolve_pids(_node, %Config{processes: processes}) when processes != :pids, do: {:ok, []}

  defp resolve_pids(node, config) do
    Enum.reduce_while(config.pids, {:ok, []}, fn pid_string, {:ok, pids} ->
      case Voyager.Pid.resolve(node, pid_string) do
        {:ok, pid} -> {:cont, {:ok, [pid | pids]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp down_reason(:noconnection), do: :node_down
  defp down_reason(reason), do: {:tracer_down, reason}

  # Batches are dropped here too, so a flood cannot grow this process' mailbox either.
  defp overloaded? do
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)
    len > @max_mailbox
  end

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Voyager.PubSub, @topic, message)
end
