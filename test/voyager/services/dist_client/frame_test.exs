defmodule Voyager.Services.DistClient.FrameTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.DistClient.Etf
  alias Voyager.Services.DistClient.Frame

  @budget %{atoms: 50_000, funs: 10_000}
  @none %{atoms: 0, funs: 0}

  test "decodes a pass-through frame into its control message, payload and cost" do
    frame = IO.iodata_to_binary(Frame.send(self(), :hello))

    assert {:control, {2, :"", pid}, payload, @none} = Frame.decode(frame, @budget)
    assert pid == self()
    assert Frame.decode_payload(payload) == {:ok, :hello}
  end

  test "rejects compressed terms" do
    compressed = :erlang.term_to_binary(:binary.copy(<<0>>, 10_000), compressed: 9)

    assert Frame.decode(<<112, compressed::binary>>, @budget) == :rejected
    assert Frame.decode_payload(compressed) == :rejected
  end

  test "creates new atoms only within the budget" do
    name = unique_name()
    frame = <<112, 131, 119, byte_size(name), name::binary>>

    assert Frame.decode(frame, @none) == :rejected
    assert {:control, atom, "", %{atoms: 1, funs: 0}} = Frame.decode(frame, @budget)
    assert Atom.to_string(atom) == name
  end

  test "counts a repeated new atom once, however large the frame" do
    name = unique_name()
    atom = <<119, byte_size(name), name::binary>>
    filler = <<109, 100_000::32, :binary.copy("wsvd", 25_000)::binary>>
    frame = <<112, 131, 104, 3, atom::binary, atom::binary, filler::binary>>

    assert {:control, {_, _, _}, "", %{atoms: 1}} = Frame.decode(frame, %{@budget | atoms: 1})
  end

  test "adds funs and exports only within the budget" do
    frame = <<112, :erlang.term_to_binary({&Enum.map/2, fn -> :ok end})::binary>>

    assert Frame.decode(frame, %{@budget | funs: 1}) == :rejected
    assert {:control, {_, _}, "", %{funs: 2}} = Frame.decode(frame, @budget)
  end

  test "unsolicited payloads may not add atoms or funs" do
    assert Frame.decode_payload(<<131, 119, 20, "voyager_unknown_atom">>) == :rejected
    assert Frame.decode_payload(:erlang.term_to_binary(&Enum.map/2)) == :rejected
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

    assert Etf.scan(:erlang.term_to_binary(term)) == {:ok, @none}
    assert Etf.scan(:erlang.term_to_binary(term, minor_version: 1)) == {:ok, @none}
  end

  defp unique_name, do: "voyager_frame_test_#{System.unique_integer([:positive])}"
end
