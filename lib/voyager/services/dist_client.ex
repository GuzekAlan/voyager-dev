defmodule Voyager.Services.DistClient do
  @moduledoc """
  Speaks the Erlang distribution protocol to one remote node over a plain TCP
  socket, without starting distribution in this VM.

  Only the results of calls made through `call/5` are accepted. Every other
  control message from the remote node (spawn requests, sends to `rex` or
  `net_kernel`, links, exit signals) is dropped, so the remote node cannot run
  code in this VM.
  """

  use GenServer, restart: :temporary

  alias Voyager.Services.DistClient.Frame
  alias Voyager.Services.DistClient.Handshake

  require Logger

  @registry Voyager.Services.DistClient.Registry
  @supervisor Voyager.Services.DistClient.Supervisor
  @connect_timeout 5_000
  @tick_interval 15_000
  @net_ticktime 60_000
  @max_frame 64 * 1024 * 1024
  @max_heap_words 32 * 1024 * 1024

  @type opts :: [
          node: node(),
          address: :inet.ip_address() | charlist(),
          port: :inet.port_number(),
          cookie: String.t(),
          name_type: :longnames | :shortnames
        ]

  @typedoc "Raw outcome of a call; `Voyager.Erpc.Socket` maps it to `:erpc.call/5` semantics."
  @type outcome :: {:down, term()} | {:spawn_error, term()} | :timeout

  @spec start(opts()) :: {:ok, pid()} | {:error, term()}
  def start(opts), do: DynamicSupervisor.start_child(@supervisor, {__MODULE__, opts})

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec stop(pid()) :: :ok
  def stop(client) do
    GenServer.stop(client)
  catch
    :exit, _ -> :ok
  end

  @spec whereis(node()) :: pid() | nil
  def whereis(node) do
    case Registry.lookup(@registry, node) do
      [{client, _local_node}] -> client
      [] -> nil
    end
  end

  @doc "The node name this VM announced to `node`, or `nil` when no client is connected to it."
  @spec local_node(node()) :: node() | nil
  def local_node(node) do
    case Registry.lookup(@registry, node) do
      [{_client, local_node}] -> local_node
      [] -> nil
    end
  end

  @spec call(pid(), module(), atom(), [term()], timeout()) :: outcome()
  def call(client, mod, fun, args, timeout) do
    GenServer.call(client, {:call, mod, fun, args, timeout}, :infinity)
  catch
    :exit, _ -> {:down, :noconnection}
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:max_heap_size, %{size: @max_heap_words, kill: true, error_logger: false})

    node = Keyword.fetch!(opts, :node)
    me = local_name(Keyword.get(opts, :name_type, :longnames))
    creation = Handshake.random_creation()

    with {:ok, socket} <- connect(opts[:address], opts[:port]),
         {:ok, _peer} <- handshake(socket, me, opts[:cookie], creation),
         {:ok, _owner} <- Registry.register(@registry, node, String.to_atom(me)) do
      :ok = :inet.setopts(socket, packet: 4, packet_size: @max_frame, active: :once)
      schedule_tick()

      {:ok,
       %{
         node: node,
         socket: socket,
         me: me,
         creation: creation,
         self_pid: Frame.pid(me, creation),
         counter: 0,
         pending: %{},
         last_recv: now()
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:call, mod, fun, args, timeout}, from, state) do
    ref = Frame.ref(state.me, state.creation, state.counter)

    request =
      Frame.spawn_request(ref, state.self_pid, {:erpc, :execute_call, [ref, mod, fun, args]})

    case :gen_tcp.send(state.socket, request) do
      :ok ->
        call = %{from: from, timer: start_timer(ref, timeout), remote_pid: nil}

        {:noreply,
         %{state | counter: state.counter + 1, pending: Map.put(state.pending, ref, call)}}

      {:error, reason} ->
        {:stop, {:shutdown, reason}, {:down, :noconnection}, state}
    end
  end

  @impl GenServer
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    :ok = :inet.setopts(socket, active: :once)
    {:noreply, handle_frame(Frame.decode(data), %{state | last_recv: now()})}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state),
    do: {:stop, {:shutdown, :closed}, state}

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state),
    do: {:stop, {:shutdown, reason}, state}

  def handle_info(:tick, state) do
    if now() - state.last_recv > @net_ticktime do
      {:stop, {:shutdown, :tick_timeout}, state}
    else
      :ok = :gen_tcp.send(state.socket, <<>>)
      schedule_tick()
      {:noreply, state}
    end
  end

  def handle_info({:call_timeout, ref}, state) do
    case Map.pop(state.pending, ref) do
      {nil, _pending} ->
        {:noreply, state}

      {call, pending} ->
        GenServer.reply(call.from, :timeout)

        if call.remote_pid,
          do: send_frame(state, Frame.exit2(state.self_pid, call.remote_pid, :kill))

        {:noreply, %{state | pending: pending}}
    end
  end

  defp handle_frame(:tick, state), do: state

  defp handle_frame({:control, {31, ref, _to, _flags, remote_pid}, _payload}, state)
       when is_pid(remote_pid) do
    case state.pending do
      %{^ref => call} ->
        %{state | pending: Map.put(state.pending, ref, %{call | remote_pid: remote_pid})}

      _other ->
        state
    end
  end

  defp handle_frame({:control, {31, ref, _to, _flags, reason}, _payload}, state),
    do: finish(state, ref, {:spawn_error, reason})

  defp handle_frame({:control, {21, _from, _to, ref, reason}, _payload}, state),
    do: finish(state, ref, {:down, reason})

  defp handle_frame({:control, {28, _from, _to, ref}, payload}, state),
    do: finish(state, ref, {:down, :erlang.binary_to_term(payload)})

  defp handle_frame({:control, {op, _from, _to}, payload}, state) when op in [2, 22, 33] do
    case :erlang.binary_to_term(payload) do
      {:io_request, from, reply_as, request} when is_pid(from) ->
        send_frame(state, Frame.send(from, {:io_reply, reply_as, io_result(request)}))

      _message ->
        drop(state, op)
    end

    state
  end

  defp handle_frame({:control, control, _payload}, state)
       when is_tuple(control) and tuple_size(control) > 0 do
    drop(state, elem(control, 0))
    state
  end

  defp handle_frame(_frame, state) do
    drop(state, :unknown)
    state
  end

  defp finish(state, ref, outcome) do
    case Map.pop(state.pending, ref) do
      {nil, _pending} ->
        state

      {call, pending} ->
        if call.timer, do: Process.cancel_timer(call.timer)
        GenServer.reply(call.from, outcome)
        %{state | pending: pending}
    end
  end

  # Output from remote code is discarded; MFA-style put_chars must never be applied here.
  defp io_result(request)
       when is_tuple(request) and tuple_size(request) > 1 and elem(request, 0) == :put_chars,
       do: :ok

  defp io_result(_request), do: {:error, :enotsup}

  defp drop(state, op) do
    Logger.warning("Dropped distribution message #{inspect(op)} from #{state.node}")
  end

  defp send_frame(state, frame), do: :gen_tcp.send(state.socket, frame)

  defp connect(address, port) do
    family = if is_tuple(address) and tuple_size(address) == 8, do: [:inet6], else: []
    opts = [:binary, packet: 2, active: false, nodelay: true] ++ family

    case :gen_tcp.connect(address, port, opts, @connect_timeout) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:error, {:node_unreachable, reason}}
    end
  end

  defp handshake(socket, me, cookie, creation) do
    case Handshake.run(socket, me, cookie, creation, @connect_timeout) do
      {:ok, peer} ->
        {:ok, peer}

      {:error, _} = error ->
        :gen_tcp.close(socket)
        error
    end
  end

  defp local_name(name_type) do
    suffix = 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    host = if name_type == :shortnames, do: "localhost", else: "127.0.0.1"
    "voyager_#{suffix}@#{host}"
  end

  defp start_timer(_ref, :infinity), do: nil
  defp start_timer(ref, timeout), do: Process.send_after(self(), {:call_timeout, ref}, timeout)

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval)

  defp now, do: System.monotonic_time(:millisecond)
end
