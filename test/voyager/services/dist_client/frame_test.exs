defmodule Voyager.Services.DistClient.FrameTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.DistClient.Frame

  test "decodes a pass-through frame into its control message and payload" do
    frame = IO.iodata_to_binary(Frame.send(self(), :hello))

    assert {:control, {2, :"", pid}, payload} = Frame.decode(frame)
    assert pid == self()
    assert Frame.decode_payload(payload) == {:ok, :hello}
  end

  test "rejects compressed terms" do
    compressed = :erlang.term_to_binary(:binary.copy(<<0>>, 10_000), compressed: 9)

    assert Frame.decode(<<112, compressed::binary>>) == :rejected
    assert Frame.decode_payload(compressed) == :rejected
  end

  test "rejects a frame that could create more atoms than the table has room for" do
    budget = :erlang.system_info(:atom_limit) - :erlang.system_info(:atom_count)

    assert Frame.decode_payload(<<131, :binary.copy(<<119>>, budget)::binary>>) == :rejected
  end

  test "rejects frames that are not pass-through" do
    assert Frame.decode(<<1, 2, 3>>) == :rejected
  end
end
