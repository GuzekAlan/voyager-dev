defmodule Voyager.Services.DistClientTest do
  # async: false because the tests assert this VM never becomes distributed.
  use ExUnit.Case, async: false

  import Mox

  alias Voyager.Agent
  alias Voyager.Erpc
  alias Voyager.Erpc.Socket
  alias Voyager.NodeSession.Connectors
  alias Voyager.Services.DistClient

  @moduletag :integration
  @moduletag :capture_log
  @cookie "dist-client-test"
  @localhost {127, 0, 0, 1}

  setup do
    {_output, 0} = System.cmd("epmd", ["-daemon"])
    name = :"target_#{System.unique_integer([:positive])}"

    {:ok, peer, node} =
      :peer.start(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: [~c"-setcookie", String.to_charlist(@cookie)]
      })

    on_exit(fn -> stop_peer(peer) end)

    {:port, port, _version} = :erl_epmd.port_please(Atom.to_charlist(name), @localhost)
    opts = [node: node, address: @localhost, port: port, cookie: @cookie]

    %{peer: peer, node: node, opts: opts}
  end

  test "calls functions on the node without distributing this VM",
       %{peer: peer, node: node} = ctx do
    start_supervised!({DistClient, ctx.opts})

    assert Socket.call(node, :erlang, :node, [], 5_000) == node

    assert Socket.call(node, :erlang, :system_info, [:otp_release], 5_000) ==
             :peer.call(peer, :erlang, :system_info, [:otp_release])

    refute Node.alive?()
  end

  test "fails the same way as :erpc.call/5", %{node: node} = ctx do
    start_supervised!({DistClient, ctx.opts})

    assert safe_call(node, :erlang, :error, [:boom]) == {:error, {:remote_exception, :boom}}
    assert safe_call(node, :erlang, :throw, [:ball]) == {:error, {:remote_throw, :ball}}
    assert safe_call(node, :erlang, :exit, [:bye]) == {:error, {:remote_exit, {:exception, :bye}}}
    assert safe_call(node, :timer, :sleep, [1_000], 50) == {:error, :timeout}
    assert safe_call(node, :erlang, :node, []) == {:ok, node}
  end

  test "rejects a wrong cookie", ctx do
    assert DistClient.start(Keyword.put(ctx.opts, :cookie, "wrong")) == {:error, :bad_cookie}
  end

  test "stops when the node goes down", %{peer: peer} = ctx do
    client = start_supervised!({DistClient, ctx.opts})
    ref = Process.monitor(client)

    stop_peer(peer)

    assert_receive {:DOWN, ^ref, :process, ^client, {:shutdown, :closed}}, 5_000
  end

  test "installs the agent watching the client's node name", %{peer: peer, node: node} = ctx do
    stub_with(Voyager.ErpcMock, Socket)
    start_supervised!({DistClient, ctx.opts})

    assert Agent.install(node) == :ok

    agent = :peer.call(peer, :erlang, :whereis, [Agent.module()])
    {:state, watched} = :peer.call(peer, :sys, :get_state, [agent])
    assert Map.keys(watched) == [DistClient.local_node(node)]
  end

  test "parses pid strings of the connected node", %{node: node} = ctx do
    stub_with(Voyager.ErpcMock, Socket)
    start_supervised!({DistClient, ctx.opts})
    on_exit(fn -> Voyager.Pid.put_node(nil) end)

    Voyager.Pid.put_node(node)
    pid = Socket.call(node, :erlang, :whereis, [:init], 5_000)

    assert pid |> Voyager.Pid.format(:distribution) |> Voyager.Pid.parse() == pid
  end

  test "the socket connector reports a node missing from epmd" do
    assert Connectors.Socket.connect("nobody@127.0.0.1", @cookie, []) ==
             {:error, :node_not_registered}
  end

  test "the node cannot run code in this VM", %{peer: peer, node: node} = ctx do
    Process.register(self(), :dist_client_test_probe)
    probe = [:dist_client_test_probe, :pwned]
    file = Path.join(System.tmp_dir!(), "dist_client_#{System.unique_integer([:positive])}")

    start_supervised!({DistClient, ctx.opts})
    me = DistClient.local_node(node)
    group_leader = Socket.call(node, :erlang, :group_leader, [], 5_000)
    remote_pid = :peer.call(peer, :erlang, :whereis, [:init])

    assert {:error, {:erpc, :notsup}} =
             peer_call(peer, :erpc, :call, [me, :erlang, :send, probe, 1_000])

    assert {:badrpc, :notsup} = peer_call(peer, :rpc, :call, [me, :erlang, :send, probe, 1_000])

    peer_send(peer, {:rex, me}, {remote_pid, {:call, :erlang, :send, probe, :user}})

    peer_send(
      peer,
      {:net_kernel, me},
      {:"$gen_call", {remote_pid, make_ref()}, {:spawn, :erlang, :send, probe, group_leader}}
    )

    peer_send(
      peer,
      {:file_server_2, me},
      {:"$gen_call", {remote_pid, make_ref()}, {:open, file, [:write]}}
    )

    peer_send(
      peer,
      group_leader,
      {:io_request, remote_pid, make_ref(), {:put_chars, :unicode, :erlang, :send, probe}}
    )

    :peer.call(peer, :erlang, :exit, [group_leader, :kill])
    :peer.call(peer, :erlang, :link, [group_leader])

    assert Socket.call(node, :erlang, :node, [], 5_000) == node
    refute_receive :pwned, 500
    refute File.exists?(file)
    refute Node.alive?()
  end

  defp safe_call(node, mod, fun, args, timeout \\ 5_000) do
    {:ok, Socket.call(node, mod, fun, args, timeout)}
  catch
    kind, reason -> Erpc.format_error(kind, reason)
  end

  defp peer_call(peer, mod, fun, args) do
    :peer.call(peer, mod, fun, args)
  catch
    :error, reason -> {:error, reason}
  end

  defp peer_send(peer, dest, message), do: :peer.call(peer, :erlang, :send, [dest, message])

  defp stop_peer(peer) do
    :peer.stop(peer)
  catch
    :exit, _ -> :ok
  end
end
