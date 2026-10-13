defmodule Voyager.Services.DistClient.FrameTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.DistClient.Etf
  alias Voyager.Services.DistClient.Frame

  @budget Frame.session_budget()

  test "decodes a pass-through frame into its control message, payload and cost" do
    frame = IO.iodata_to_binary(Frame.send(self(), :hello))

    assert {:control, {2, :"", pid}, payload, %{atoms: 50_000}} = Frame.decode(frame, @budget)

    assert pid == self()
    assert {:ok, :hello, _budget} = Frame.decode_payload(payload, @budget)
  end

  test "rejects compressed terms" do
    compressed = :erlang.term_to_binary(:binary.copy(<<0>>, 10_000), compressed: 9)

    assert Frame.decode(<<112, compressed::binary>>, @budget) == :rejected
    assert Frame.decode_payload(compressed, @budget) == :rejected
  end

  test "creates new atoms only within the budget" do
    name = unique_name()
    frame = <<112, 131, 119, byte_size(name), name::binary>>

    assert Frame.decode(frame, %{@budget | atoms: 0}) == :rejected
    assert {:control, atom, "", %{atoms: 49_999}} = Frame.decode(frame, @budget)
    assert Atom.to_string(atom) == name
  end

  test "counts a repeated new atom once, however large the frame" do
    name = unique_name()
    atom = <<119, byte_size(name), name::binary>>
    filler = <<109, 100_000::32, :binary.copy("wsvd", 25_000)::binary>>
    frame = <<112, 131, 104, 3, atom::binary, atom::binary, filler::binary>>

    assert {:control, {_, _, _}, "", %{atoms: 0}} = Frame.decode(frame, %{@budget | atoms: 1})
  end

  test "counts each distinct fun and export once per session" do
    frame = <<112, :erlang.term_to_binary({&Enum.map/2, fn -> :ok end})::binary>>

    assert {:control, {_, _}, "", %{funs: funs} = budget} = Frame.decode(frame, @budget)
    assert MapSet.size(funs) == 2
    assert {:control, {_, _}, "", %{funs: ^funs}} = Frame.decode(frame, budget)
  end

  test "unsolicited payloads may not add atoms or funs" do
    assert Frame.decode_payload(<<131, 119, 20, "voyager_unknown_atom">>, @budget) == :rejected
    assert Frame.decode_payload(:erlang.term_to_binary(&Enum.map/2), @budget) == :rejected
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

  test "rejects frames that are not pass-through" do
    assert Frame.decode(<<1, 2, 3>>, @budget) == :rejected
  end

  test "the scan agrees with the decoder on every term shape Voyager receives" do
    term = %{
      list: [1, -2, 3.5, 2 ** 70, -(2 ** 300), "bin", <<1::3>>, ~c"chars", [] | :tail],
      tuple: {self(), make_ref(), hd(Port.list()), :atom, {}},
      map: %{nested: %{}}
    }

    empty = MapSet.new()
    assert {:ok, %{atoms: 0, funs: ^empty}} = Etf.scan(:erlang.term_to_binary(term))

    assert {:ok, %{atoms: 0, funs: ^empty}} =
             Etf.scan(:erlang.term_to_binary(term, minor_version: 1))
  end

  test "counts the same bytes as latin1 and as utf8 as two atoms" do
    name = "voyager_é_#{System.unique_integer([:positive])}"

    term =
      <<131, 104, 2, 100, byte_size(name)::16, name::binary, 118, byte_size(name)::16,
        name::binary>>

    assert {:ok, %{atoms: 2}} = Etf.scan(term)
  end

  test "caps the distinct node incarnations a session may decode" do
    pids = for creation <- 1..1_001, do: <<88, 119, 2, "ok", 1::32, 0::32, creation::32>>
    payload = IO.iodata_to_binary([131, 108, <<length(pids)::32>>, pids, 106])

    assert Frame.decode_payload(payload, @budget) == :rejected

    same_node = for id <- 1..1_001, do: <<88, 119, 2, "ok", id::32, 0::32, 7::32>>
    payload = IO.iodata_to_binary([131, 108, <<length(same_node)::32>>, same_node, 106])

    assert {:ok, _pids, %{nodes: nodes}} = Frame.decode_payload(payload, @budget)
    assert MapSet.size(nodes) == 1
  end

  defp unique_name, do: "voyager_frame_test_#{System.unique_integer([:positive])}"
end
