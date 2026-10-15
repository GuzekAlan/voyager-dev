defmodule Voyager.Services.Tracer do
  @moduledoc """
  Owns the single tracing session of this Voyager instance; the UI and MCP both go through it.

  The tracer on the remote node pushes event batches straight to this process.
  The newest events are kept in memory and everything is broadcast on `topic/0`
  as `{:tracing_started, session}`, `{:trace_events, session, events}` and
  `{:tracing_ended, session}`.
  """

  use GenServer

  alias Voyager.Agent

  @topic "tracing"
  @kept_events 500
  @max_mailbox 1_000

  @type origin :: :ui | :mcp

  @type session :: %{
          id: pos_integer(),
          node: node(),
          spec: map(),
          limits: map(),
          origin: origin(),
          tracer: pid(),
          status: :running | :ended,
          stop_reason: term(),
          events: non_neg_integer(),
          dropped: non_neg_integer(),
          started_at: DateTime.t(),
          ended_at: DateTime.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Starts tracing on `node` with the agent's `spec` and `limits`, which the agent validates.
  Returns `{:error, :busy}` while another session runs.
  """
  @spec start(node(), map(), map(), origin()) :: {:ok, session()} | {:error, term()}
  def start(node, spec, limits, origin) when origin in [:ui, :mcp] do
    GenServer.call(
      __MODULE__,
      {:start, node, spec, limits, origin},
      Agent.default_timeout() + 1_000
    )
  end

  @doc """
  Asks the remote tracer to stop; `tracing_ended` follows with `reason`.
  Stops any session, whoever started it.
  """
  @spec stop(term()) :: :ok
  def stop(reason \\ :stopped),
    do: GenServer.call(__MODULE__, {:stop, reason}, Agent.default_timeout() + 1_000)

  @doc "The running or last session and its kept events, newest first."
  @spec current() :: {session() | nil, [map()]}
  def current, do: GenServer.call(__MODULE__, :current)

  @impl true
  def init(nil), do: {:ok, %{session: nil, events: [], dropped_here: 0, stopping: nil}}

  @impl true
  def handle_call(
        {:start, _node, _spec, _limits, _origin},
        _from,
        %{session: %{status: :running}} = state
      ) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:start, node, spec, limits, origin}, _from, state) do
    case Agent.call(node, :trace_start, [self(), spec, limits], Agent.default_timeout()) do
      {:ok, {:ok, tracer}} ->
        Process.monitor(tracer)

        session = %{
          id: System.unique_integer([:positive]),
          node: node,
          spec: spec,
          limits: limits,
          origin: origin,
          tracer: tracer,
          status: :running,
          stop_reason: nil,
          events: 0,
          dropped: 0,
          started_at: DateTime.utc_now(),
          ended_at: nil
        }

        broadcast({:tracing_started, session})

        Voyager.Telemetry.dispatch!("voyager.trace.start",
          metadata: Map.put(spec_metadata(spec), :origin, origin)
        )

        {:reply, {:ok, session},
         %{state | session: session, events: [], dropped_here: 0, stopping: nil}}

      {:ok, {:error, reason}} ->
        start_failed(reason, origin, state)

      {:error, reason} ->
        start_failed(reason, origin, state)
    end
  end

  # The session ends on the tracer's done message or its DOWN, never on this reply.
  def handle_call({:stop, reason}, _from, %{session: %{status: :running} = session} = state) do
    Agent.call(session.node, :trace_stop, [session.tracer], Agent.default_timeout())
    {:reply, :ok, %{state | stopping: reason}}
  end

  def handle_call({:stop, _reason}, _from, state), do: {:reply, :ok, state}

  def handle_call(:current, _from, state), do: {:reply, {state.session, state.events}, state}

  @impl true
  def handle_info(
        {:voyager_trace_events, tracer, events, dropped},
        %{session: %{tracer: tracer, status: :running} = session} = state
      ) do
    if overloaded?() do
      dropped_here = state.dropped_here + length(events)
      session = %{session | dropped: dropped + dropped_here}
      {:noreply, %{state | session: session, dropped_here: dropped_here}}
    else
      events = Enum.with_index(events, fn event, i -> Map.put(event, :id, session.events + i) end)

      session = %{
        session
        | events: session.events + length(events),
          dropped: dropped + state.dropped_here
      }

      broadcast({:trace_events, session, events})

      kept = Enum.take(Enum.reverse(events) ++ state.events, @kept_events)
      {:noreply, %{state | session: session, events: kept}}
    end
  end

  def handle_info(
        {:voyager_trace_done, tracer, reason, %{dropped: dropped}},
        %{session: %{tracer: tracer, status: :running}} = state
      ) do
    {:noreply, finish(state, reason, dropped + state.dropped_here)}
  end

  def handle_info(
        {:DOWN, _ref, :process, tracer, reason},
        %{session: %{tracer: tracer, status: :running} = session} = state
      ) do
    {:noreply, finish(state, down_reason(reason), session.dropped)}
  end

  def handle_info(_stale, state), do: {:noreply, state}

  defp finish(state, reason, dropped) do
    session = %{
      state.session
      | status: :ended,
        stop_reason: state.stopping || reason,
        dropped: dropped,
        ended_at: DateTime.utc_now()
    }

    broadcast({:tracing_ended, session})

    Voyager.Telemetry.dispatch!("voyager.trace.stop",
      measurements: %{
        events: session.events,
        dropped: session.dropped,
        duration_ms: DateTime.diff(session.ended_at, session.started_at, :millisecond)
      },
      metadata: %{origin: session.origin, reason: session.stop_reason}
    )

    %{state | session: session, stopping: nil}
  end

  defp start_failed(reason, origin, state) do
    Voyager.Telemetry.dispatch!("voyager.trace.start_failed",
      metadata: %{origin: origin, reason: reason}
    )

    {:reply, {:error, reason}, state}
  end

  defp spec_metadata(spec) do
    spec
    |> Map.take([:capture, :scope, :return_trace])
    |> Map.merge(%{
      processes: if(is_list(spec[:processes]), do: :pids, else: spec[:processes]),
      match_spec?: spec[:match_spec] != :undefined
    })
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
