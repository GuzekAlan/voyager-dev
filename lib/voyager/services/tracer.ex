defmodule Voyager.Services.Tracer do
  @moduledoc """
  Owns the active tracing session of this Voyager instance; the UI and MCP both go through it.

  A session is created, configured, then switched on and off with `start/0` and
  `stop/0`; starting a stopped session resumes it. The tracer on the remote node
  pushes event batches straight to this process. The newest events are kept in
  memory and everything is broadcast on `topic/0` as
  `{:session_created, session}`, `{:session_closed, id}`,
  `{:tracing_configured, session}`, `{:tracing_started, session}`,
  `{:trace_events, session, events}` and `{:tracing_ended, session}`.
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
  @spec configure(node(), map()) ::
          {:ok, Session.t()} | {:error, :no_session | :busy | Ecto.Changeset.t() | term()}
  def configure(node, attrs) do
    with {:ok, config} <- attrs |> Config.changeset() |> Ecto.Changeset.apply_action(:validate),
         {:ok, pids} <- resolve_pids(node, config) do
      GenServer.call(__MODULE__, {:configure, node, config, Config.to_agent(config, pids)})
    end
  end

  @doc "Starts or resumes the configured session; the agent's refusals come back as `{:error, reason}`."
  @spec start() :: {:ok, Session.t()} | {:error, term()}
  def start, do: GenServer.call(__MODULE__, :start, @call_timeout)

  @doc """
  Asks the remote tracer to stop; `tracing_ended` follows with `:stopped`.
  Stops any session, whoever started it.
  """
  @spec stop() :: :ok
  def stop, do: GenServer.call(__MODULE__, :stop, @call_timeout)

  @doc """
  Ends a running session with `:disconnected` once its tracer goes down, without calling the node.
  The remote tracer stops by itself when this node disconnects.
  """
  @spec disconnected() :: :ok
  def disconnected, do: GenServer.cast(__MODULE__, :disconnected)

  @doc "The active session and its kept events, newest first."
  @spec active() :: {Session.t() | nil, [map()]}
  def active, do: GenServer.call(__MODULE__, :active)

  @impl true
  def init(nil),
    do: {:ok, %{session: nil, agent_args: nil, events: [], run: nil}}

  @impl true
  def handle_call(request, _from, %{session: %Session{status: :running}} = state)
      when request in [:start, :close] or
             (is_tuple(request) and elem(request, 0) in [:create, :configure]),
      do: {:reply, {:error, :busy}, state}

  def handle_call({:create, origin, save}, _from, state) do
    session = %Session{
      id: System.unique_integer([:positive]),
      origin: origin,
      save: save,
      created_at: DateTime.utc_now()
    }

    broadcast({:session_created, session})
    {:reply, {:ok, session}, %{state | session: session, agent_args: nil, events: []}}
  end

  def handle_call(:close, _from, %{session: nil} = state), do: {:reply, :ok, state}

  def handle_call(:close, _from, %{session: session} = state) do
    broadcast({:session_closed, session.id})
    {:reply, :ok, %{state | session: nil, agent_args: nil, events: []}}
  end

  def handle_call({:configure, _node, _config, _agent_args}, _from, %{session: nil} = state),
    do: {:reply, {:error, :no_session}, state}

  def handle_call({:configure, node, config, agent_args}, _from, state) do
    session = %{state.session | node: node, config: config}
    broadcast({:tracing_configured, session})
    {:reply, {:ok, session}, %{state | session: session, agent_args: agent_args}}
  end

  def handle_call(:start, _from, %{session: nil} = state),
    do: {:reply, {:error, :no_session}, state}

  def handle_call(:start, _from, %{session: %Session{config: nil}} = state),
    do: {:reply, {:error, :not_configured}, state}

  def handle_call(:start, _from, %{session: session} = state) do
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

        broadcast({:tracing_started, session})

        Voyager.Telemetry.dispatch!("voyager.trace.start",
          metadata:
            session.config
            |> Map.take([:capture, :scope, :return_trace, :processes])
            |> Map.put(:origin, session.origin)
        )

        run = %{
          events: session.events,
          dropped: session.dropped,
          dropped_here: 0,
          stopping: nil,
          at: System.monotonic_time()
        }

        {:reply, {:ok, session}, %{state | session: session, run: run}}

      {:ok, {:error, reason}} ->
        start_failed(reason, state)

      {:error, reason} ->
        start_failed(reason, state)
    end
  end

  # The session ends on the tracer's done message or its DOWN, never on this reply.
  def handle_call(:stop, _from, %{session: %{status: :running} = session} = state) do
    Agent.call(session.node, :trace_stop, [session.tracer], Agent.default_timeout())
    {:reply, :ok, %{state | run: %{state.run | stopping: :stopped}}}
  end

  def handle_call(:stop, _from, state), do: {:reply, :ok, state}

  def handle_call(:active, _from, state), do: {:reply, {state.session, state.events}, state}

  @impl true
  def handle_cast(:disconnected, %{session: %{status: :running}} = state),
    do: {:noreply, %{state | run: %{state.run | stopping: :disconnected}}}

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
    # Ids count dropped events too, so a gap marks where they were lost.
    events = Enum.with_index(events, &Map.put(&1, :id, session.events + dropped + &2))

    session = %{
      session
      | events: session.events + length(events),
        dropped: dropped
    }

    broadcast({:trace_events, session, events})

    kept = Enum.take(Enum.reverse(events) ++ state.events, @kept_events)

    {:noreply,
     %{state | session: session, events: kept, run: %{run | dropped_here: dropped_here}}}
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
    session = %{
      state.session
      | status: :stopped,
        stop_reason: run.stopping || reason,
        dropped: dropped,
        ended_at: DateTime.utc_now()
    }

    broadcast({:tracing_ended, session})

    Voyager.Telemetry.dispatch!("voyager.trace.stop",
      measurements: %{
        events: session.events - run.events,
        dropped: session.dropped - run.dropped,
        duration_ms:
          System.convert_time_unit(System.monotonic_time() - run.at, :native, :millisecond)
      },
      metadata: %{origin: session.origin, reason: session.stop_reason}
    )

    %{state | session: session, run: nil}
  end

  defp start_failed(reason, state) do
    Voyager.Telemetry.dispatch!("voyager.trace.start_failed",
      metadata: %{origin: state.session.origin, reason: reason}
    )

    {:reply, {:error, reason}, state}
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
