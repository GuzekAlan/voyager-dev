defmodule Voyager.Services.DistClient.Etf do
  @moduledoc false

  @type cost :: %{atoms: non_neg_integer(), funs: non_neg_integer()}

  @doc """
  Walks an external term without decoding it and counts what decoding would add
  to the VM's never-freed tables: distinct new atoms, and funs plus exports.
  Tags distribution never sends to us (compressed, atom cache, old pid forms)
  return `:error`.
  """
  @spec scan(binary()) :: {:ok, cost()} | :error
  def scan(<<131, rest::binary>>), do: walk(rest, 1, MapSet.new(), 0)
  def scan(_other), do: :error

  defp walk(_rest, 0, atoms, funs), do: {:ok, %{atoms: MapSet.size(atoms), funs: funs}}

  defp walk(binary, pending, atoms, funs) do
    case term(binary, atoms) do
      {:ok, rest, children, atoms, fun} -> walk(rest, pending - 1 + children, atoms, funs + fun)
      :error -> :error
    end
  end

  defp term(<<97, _::8, rest::binary>>, atoms), do: leaf(rest, atoms)
  defp term(<<98, _::32, rest::binary>>, atoms), do: leaf(rest, atoms)
  defp term(<<70, _::64, rest::binary>>, atoms), do: leaf(rest, atoms)
  defp term(<<106, rest::binary>>, atoms), do: leaf(rest, atoms)
  defp term(<<110, n::8, _sign, _::binary-size(n), rest::binary>>, atoms), do: leaf(rest, atoms)
  defp term(<<111, n::32, _sign, _::binary-size(n), rest::binary>>, atoms), do: leaf(rest, atoms)
  defp term(<<107, n::16, _::binary-size(n), rest::binary>>, atoms), do: leaf(rest, atoms)
  defp term(<<109, n::32, _::binary-size(n), rest::binary>>, atoms), do: leaf(rest, atoms)
  defp term(<<77, n::32, _bits, _::binary-size(n), rest::binary>>, atoms), do: leaf(rest, atoms)
  defp term(<<104, n::8, rest::binary>>, atoms), do: {:ok, rest, n, atoms, 0}
  defp term(<<105, n::32, rest::binary>>, atoms), do: {:ok, rest, n, atoms, 0}
  defp term(<<108, n::32, rest::binary>>, atoms), do: {:ok, rest, n + 1, atoms, 0}
  defp term(<<116, n::32, rest::binary>>, atoms), do: {:ok, rest, 2 * n, atoms, 0}

  defp term(<<118, n::16, name::binary-size(n), rest::binary>>, atoms),
    do: atom(name, :utf8, rest, atoms)

  defp term(<<119, n::8, name::binary-size(n), rest::binary>>, atoms),
    do: atom(name, :utf8, rest, atoms)

  defp term(<<100, n::16, name::binary-size(n), rest::binary>>, atoms),
    do: atom(name, :latin1, rest, atoms)

  defp term(<<115, n::8, name::binary-size(n), rest::binary>>, atoms),
    do: atom(name, :latin1, rest, atoms)

  defp term(<<88, rest::binary>>, atoms), do: with_node(rest, atoms, 12)
  defp term(<<89, rest::binary>>, atoms), do: with_node(rest, atoms, 8)
  defp term(<<120, rest::binary>>, atoms), do: with_node(rest, atoms, 12)
  defp term(<<90, len::16, rest::binary>>, atoms), do: with_node(rest, atoms, 4 + 4 * len)

  # NEW_FUN_EXT: module, old index, old uniq and pid, then the free variables.
  defp term(
         <<112, _size::32, _arity, _uniq::binary-size(16), _index::32, free::32, rest::binary>>,
         atoms
       ),
       do: {:ok, rest, 4 + free, atoms, 1}

  # EXPORT_EXT: module, function, arity.
  defp term(<<113, rest::binary>>, atoms), do: {:ok, rest, 3, atoms, 1}
  defp term(_other, _atoms), do: :error

  defp leaf(rest, atoms), do: {:ok, rest, 0, atoms, 0}

  defp atom(name, encoding, rest, atoms) do
    :erlang.binary_to_existing_atom(name, encoding)
    leaf(rest, atoms)
  rescue
    ArgumentError -> leaf(rest, MapSet.put(atoms, name))
  end

  defp with_node(binary, atoms, skip) do
    with {:ok, rest, 0, atoms, 0} <- term(binary, atoms),
         <<_::binary-size(^skip), rest::binary>> <- rest do
      leaf(rest, atoms)
    else
      _ -> :error
    end
  end
end
