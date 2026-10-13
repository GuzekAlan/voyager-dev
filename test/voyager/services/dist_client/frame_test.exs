defmodule Voyager.Services.DistClient.FrameTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.DistClient.Frame

  @budget 50_000

  test "decodes a pass-through frame into its control message and payload" do
    frame = IO.iodata_to_binary(Frame.send(self(), :hello))

    assert {:control, {2, :"", pid}, payload} = Frame.decode(frame, @budget)
    assert pid == self()
    assert Frame.decode_payload(payload) == {:ok, :hello}
  end

  test "rejects compressed terms" do
    compressed = :erlang.term_to_binary(:binary.copy(<<0>>, 10_000), compressed: 9)

    assert Frame.decode(<<112, compressed::binary>>, @budget) == :rejected
    assert Frame.decode_payload(compressed) == :rejected
  end

  test "rejects a frame that could create more atoms than the table has room for" do
    budget = :erlang.system_info(:atom_limit) - :erlang.system_info(:atom_count)

    frame = <<112, 131, :binary.copy(<<119>>, budget)::binary>>

    assert Frame.decode(frame, :erlang.system_info(:atom_limit)) == :rejected
  end

  test "turns funs and local structs into data that runs nothing" do
    probe = Stream.map([:pwned], &send(self(), &1))
    inert = Frame.inert({:ok, [probe, %File.Stream{path: "/etc/hosts"}]})

    assert {:ok, [%{"__struct__" => "Stream", funs: [fun]}, %{"__struct__" => "File.Stream"}]} =
             inert

    assert is_binary(fun)
    refute is_struct(elem(inert, 1) |> hd())
  end

  test "names structs of modules that only exist on the remote node" do
    remote = %{__struct__: :"Elixir.Remote.Only.State", count: 1}

    assert Frame.inert(remote) == %{"__struct__" => "Remote.Only.State", count: 1}
  end

  test "creates new atoms only within the session's budget" do
    name = "voyager_frame_test_#{System.unique_integer([:positive])}"
    frame = <<112, 131, 119, byte_size(name), name::binary>>

    assert Frame.decode(frame, 0) == :rejected
    assert {:control, atom, ""} = Frame.decode(frame, @budget)
    assert Atom.to_string(atom) == name
  end

  test "rejects unsolicited payloads that would create atoms" do
    payload = <<131, 119, 20, "voyager_unknown_atom">>

    assert Frame.decode_payload(payload) == :rejected
  end

  test "rejects frames that are not pass-through" do
    assert Frame.decode(<<1, 2, 3>>, @budget) == :rejected
  end
end
