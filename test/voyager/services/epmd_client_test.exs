defmodule Voyager.Services.EpmdClientTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.EpmdClient

  @names_req <<1::16, 110>>

  defp start_epmd!(response) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    start_supervised!(
      {Task,
       fn ->
         {:ok, sock} = :gen_tcp.accept(listen)
         {:ok, @names_req} = :gen_tcp.recv(sock, byte_size(@names_req))
         :ok = :gen_tcp.send(sock, response)
         :gen_tcp.close(sock)
       end}
    )

    port
  end

  describe "node_port/2" do
    test "returns the distribution port of a registered node" do
      port = start_epmd!(<<4369::32, "name foo at port 51234\nname bar at port 51235\n">>)

      assert {:ok, 51_235} = EpmdClient.node_port(port, "bar")
    end

    test "returns node_not_found with the names epmd reported" do
      names = "name foo at port 51234\n"
      port = start_epmd!(<<4369::32, names::binary>>)

      assert {:error, {:node_not_found, "missing", ^names}} =
               EpmdClient.node_port(port, "missing")
    end

    test "does not match a node whose name only starts with the requested one" do
      port = start_epmd!(<<4369::32, "name foobar at port 51234\n">>)

      assert {:error, {:node_not_found, "foo", _names}} = EpmdClient.node_port(port, "foo")
    end

    test "rejects a response shorter than the epmd port header" do
      port = start_epmd!(<<1, 2>>)

      assert {:error, :invalid_epmd_response} = EpmdClient.node_port(port, "foo")
    end
  end
end
