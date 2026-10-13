defmodule Voyager.Services.DistClient.Frame do
  @moduledoc false

  @pass_through 112
  @send 2
  @exit2 8
  @spawn_request 29

  @spec decode(binary()) :: :tick | {:control, term(), binary()} | :unknown
  def decode(<<>>), do: :tick

  def decode(<<@pass_through, rest::binary>>) do
    {control, used} = :erlang.binary_to_term(rest, [:used])
    <<_control::binary-size(^used), payload::binary>> = rest
    {:control, control, payload}
  end

  def decode(_other), do: :unknown

  @spec spawn_request(reference(), pid(), {module(), atom(), [term()]}) :: iodata()
  def spawn_request(ref, from, {mod, fun, args}) do
    encode({@spawn_request, ref, from, from, {mod, fun, length(args)}, [:monitor]}, args)
  end

  @spec send(pid(), term()) :: iodata()
  def send(to, message), do: encode({@send, :"", to}, message)

  @spec exit2(pid(), pid(), term()) :: iodata()
  def exit2(from, to, reason), do: encode({@exit2, from, to, reason})

  @doc "A pid of node `name`, built from ETF so it works without distribution."
  @spec pid(String.t(), non_neg_integer()) :: pid()
  def pid(name, creation) do
    :erlang.binary_to_term(<<131, 88, atom(name)::binary, 1::32, 0::32, creation::32>>)
  end

  @spec ref(String.t(), non_neg_integer(), non_neg_integer()) :: reference()
  def ref(name, creation, counter) do
    ids = <<rem(counter, 0x40000)::32, div(counter, 0x40000)::32, :rand.uniform(0xFFFFFFFF)::32>>
    :erlang.binary_to_term(<<131, 90, 3::16, atom(name)::binary, creation::32, ids::binary>>)
  end

  defp encode(control), do: [@pass_through, :erlang.term_to_binary(control)]
  defp encode(control, message), do: [encode(control), :erlang.term_to_binary(message)]

  defp atom(name), do: <<119, byte_size(name), name::binary>>
end
