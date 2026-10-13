defmodule Voyager.Services.DistClient.Frame do
  @moduledoc false

  alias Voyager.Services.DistClient.Etf

  @pass_through 112
  @send 2
  @exit2 8
  @spawn_request 29

  @max_nodes 1_000

  @typedoc "What a session may still add to the VM's never-freed tables, and the nodes it has seen."
  @type budget :: %{atoms: integer(), funs: integer(), nodes: MapSet.t()}

  @spec session_budget() :: budget()
  def session_budget, do: %{atoms: 50_000, funs: 10_000, nodes: MapSet.new()}

  @doc "Decodes a frame within `budget` and returns the budget that is left."
  @spec decode(binary(), budget()) :: :tick | {:control, term(), binary(), budget()} | :rejected
  def decode(<<>>, _budget), do: :tick

  def decode(<<@pass_through, rest::binary>>, budget) do
    with {:ok, {control, used}, budget} <- to_term(rest, [:used], budget) do
      <<_control::binary-size(^used), payload::binary>> = rest
      {:control, inert(control), payload, budget}
    end
  end

  def decode(_other, _budget), do: :rejected

  @doc "Decodes an unsolicited message payload; it may not add atoms or funs."
  @spec decode_payload(binary(), budget()) :: {:ok, term(), budget()} | :rejected
  def decode_payload(payload, budget) do
    with {:ok, term, %{nodes: nodes}} <- to_term(payload, [], %{budget | atoms: 0, funs: 0}),
         do: {:ok, term, %{budget | nodes: nodes}}
  end

  @doc """
  Replaces funs with their inspected text and turns every struct into a plain map
  whose `"__struct__"` string key names the module, so no local function or
  protocol implementation can be reached through a term from the remote node.
  """
  @spec inert(term()) :: term()
  def inert(term) when is_function(term), do: inspect(term)
  def inert(list) when is_list(list), do: inert_list(list)

  def inert(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&inert/1) |> List.to_tuple()

  def inert(%{__struct__: mod} = struct) when is_atom(mod),
    do: struct |> inert_map() |> Map.delete(:__struct__) |> Map.put("__struct__", inspect(mod))

  def inert(map) when is_map(map), do: inert_map(map)
  def inert(term), do: term

  @spec spawn_request(reference(), pid(), {module(), atom(), [term()]}) :: iodata()
  def spawn_request(ref, from, {mod, fun, args}) do
    encode({@spawn_request, ref, from, from, {mod, fun, length(args)}, [:monitor]}, args)
  end

  @spec send(pid(), term()) :: iodata()
  def send(to, message), do: encode({@send, :"", to}, message)

  @spec exit2(pid(), pid(), term()) :: iodata()
  def exit2(from, to, reason), do: encode({@exit2, from, to, reason})

  @doc "A pid of node `name`, built from ETF so it works without distribution."
  @spec pid(String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: pid()
  def pid(name, creation, number \\ 1, serial \\ 0) do
    :erlang.binary_to_term(<<131, 88, atom(name)::binary, number::32, serial::32, creation::32>>)
  end

  @spec ref(String.t(), non_neg_integer(), non_neg_integer()) :: reference()
  def ref(name, creation, counter) do
    ids = <<rem(counter, 0x40000)::32, div(counter, 0x40000)::32, :rand.uniform(0xFFFFFFFF)::32>>
    :erlang.binary_to_term(<<131, 90, 3::16, atom(name)::binary, creation::32, ids::binary>>)
  end

  defp to_term(binary, opts, budget) do
    atom_headroom =
      div(:erlang.system_info(:atom_limit) * 9, 10) - :erlang.system_info(:atom_count)

    with {:ok, cost} <- Etf.scan(binary),
         nodes = MapSet.union(budget.nodes, cost.nodes),
         true <- cost.atoms <= min(budget.atoms, atom_headroom) and cost.funs <= budget.funs,
         true <- MapSet.size(nodes) <= @max_nodes do
      left = %{atoms: budget.atoms - cost.atoms, funs: budget.funs - cost.funs, nodes: nodes}
      {:ok, :erlang.binary_to_term(binary, opts), left}
    else
      _ -> :rejected
    end
  rescue
    ArgumentError -> :rejected
  end

  # :maps keeps protocol dispatch on `__struct__` out of the walk.
  defp inert_map(map),
    do:
      map
      |> :maps.to_list()
      |> Enum.map(fn {k, v} -> {inert(k), inert(v)} end)
      |> :maps.from_list()

  defp inert_list([head | tail]), do: [inert(head) | inert_list(tail)]
  defp inert_list([]), do: []
  defp inert_list(tail), do: inert(tail)

  defp encode(control), do: [@pass_through, :erlang.term_to_binary(control)]
  defp encode(control, message), do: [encode(control), :erlang.term_to_binary(message)]

  defp atom(name), do: <<119, byte_size(name), name::binary>>
end
