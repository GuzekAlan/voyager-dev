defmodule Voyager.Services.Tracer.Writer do
  @moduledoc """
  Saves the entries of a saved `Voyager.Services.Tracer` session, so encoding and
  database writes never run in the Tracer's mailbox. Appends are coalesced into one
  transaction per flush interval. After each flush the Tracer gets
  `{:trace_written, session_id, bytes}`, or `{:trace_write_failed, session_id, reason}`
  when the entries were dropped.
  """

  use GenServer

  alias Voyager.Actions.TraceEntries, as: TraceEntryActions
  alias Voyager.Actions.TraceSessions, as: TraceSessionActions
  alias Voyager.Repo
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Session

  require Logger

  @flush_ms 200
  # 1000 rows of ~14 columns stay far below SQLite's bound-variable limit.
  @chunk_rows 1_000
  @max_queue 50

  defstruct pending: [], session: nil, timer: nil

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Queues numbered `entries`; `session` is its state after them."
  @spec append(Session.t(), [Tracer.entry()]) :: :ok
  def append(session, entries), do: GenServer.cast(__MODULE__, {:append, session, entries})

  @doc "Flushes what is queued, then prunes older sessions over the storage limit."
  @spec close_run(Session.t()) :: :ok
  def close_run(session), do: GenServer.cast(__MODULE__, {:close_run, session})

  @doc "Blocks until everything appended so far is in the database."
  @spec flush() :: :ok
  def flush, do: GenServer.call(__MODULE__, :flush)

  @spec overloaded?() :: boolean()
  def overloaded? do
    with pid when is_pid(pid) <- Process.whereis(__MODULE__),
         {:message_queue_len, len} <- Process.info(pid, :message_queue_len) do
      len > @max_queue
    else
      _down -> false
    end
  end

  @impl true
  def init(nil), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_cast({:append, session, entries}, state) do
    state = if state.session && state.session.id != session.id, do: flush(state), else: state
    {:noreply, schedule_flush(%{state | session: session, pending: [entries | state.pending]})}
  end

  def handle_cast({:close_run, session}, state) do
    state = flush(%{state | session: session})

    with {:error, reason} <-
           guarded(fn -> TraceSessionActions.prune(session.storage_limit, session.id) end) do
      Logger.error("Pruning trace sessions failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, flush(state)}

  @impl true
  def handle_info(:flush, state), do: {:noreply, flush(%{state | timer: nil})}

  defp schedule_flush(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :flush, @flush_ms)}

  defp schedule_flush(state), do: state

  defp flush(%{pending: []} = state), do: state

  defp flush(%{session: session, pending: pending} = state) do
    entries = pending |> Enum.reverse() |> Enum.concat()

    case guarded(fn -> write(session, entries) end) do
      {:ok, bytes} ->
        send(Tracer, {:trace_written, session.id, bytes})

      {:error, reason} ->
        Logger.error("Saving trace session #{session.id} failed: #{inspect(reason)}")
        send(Tracer, {:trace_write_failed, session.id, reason})
    end

    %{state | pending: []}
  end

  defp write(session, entries) do
    {:ok, bytes} =
      Repo.transact(fn ->
        stored =
          entries
          |> Enum.chunk_every(@chunk_rows)
          |> Enum.map(&TraceEntryActions.insert_all(session.id, &1))
          |> Enum.sum()

        {:ok, TraceSessionActions.sync(session, stored)}
      end)

    bytes
  end

  defp guarded(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end
end
