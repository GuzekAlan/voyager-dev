defmodule Voyager.Services.DistClient.Etf do
  @moduledoc false

  @type cost :: %{atoms: non_neg_integer(), funs: non_neg_integer(), nodes: MapSet.t()}

  @atom_tags [100, 115, 118, 119]

  @doc """
  Walks an external term without decoding it and counts what decoding would add
  to the VM's global tables: distinct new atoms, funs plus exports, and the
  `{node, creation}` pairs behind pids, ports and references. Tags distribution
  never sends to us (compressed, atom cache, old pid forms) return `:error`.
  """
  @spec scan(binary()) :: {:ok, cost()} | :error
  def scan(<<131, rest::binary>>),
    do: walk(rest, 1, %{atoms: MapSet.new(), funs: 0, nodes: MapSet.new()})

  def scan(_other), do: :error

  defp walk(_rest, 0, acc), do: {:ok, %{acc | atoms: MapSet.size(acc.atoms)}}

  defp walk(binary, pending, acc) do
    case term(binary, acc) do
      {:ok, rest, children, acc} -> walk(rest, pending - 1 + children, acc)
      :error -> :error
    end
  end

  defp term(<<97, _::8, rest::binary>>, acc), do: {:ok, rest, 0, acc}
  defp term(<<98, _::32, rest::binary>>, acc), do: {:ok, rest, 0, acc}
  defp term(<<70, _::64, rest::binary>>, acc), do: {:ok, rest, 0, acc}
  defp term(<<106, rest::binary>>, acc), do: {:ok, rest, 0, acc}
  defp term(<<110, n::8, _sign, _::binary-size(n), rest::binary>>, acc), do: {:ok, rest, 0, acc}
  defp term(<<111, n::32, _sign, _::binary-size(n), rest::binary>>, acc), do: {:ok, rest, 0, acc}
  defp term(<<107, n::16, _::binary-size(n), rest::binary>>, acc), do: {:ok, rest, 0, acc}
  defp term(<<109, n::32, _::binary-size(n), rest::binary>>, acc), do: {:ok, rest, 0, acc}
  defp term(<<77, n::32, _bits, _::binary-size(n), rest::binary>>, acc), do: {:ok, rest, 0, acc}
  defp term(<<104, n::8, rest::binary>>, acc), do: {:ok, rest, n, acc}
  defp term(<<105, n::32, rest::binary>>, acc), do: {:ok, rest, n, acc}
  defp term(<<108, n::32, rest::binary>>, acc), do: {:ok, rest, n + 1, acc}
  defp term(<<116, n::32, rest::binary>>, acc), do: {:ok, rest, 2 * n, acc}

  defp term(<<tag, _::binary>> = binary, acc) when tag in @atom_tags do
    with {:ok, encoding, name, rest} <- atom_name(binary), do: atom(name, encoding, rest, acc)
  end

  defp term(<<88, rest::binary>>, acc), do: node(rest, acc, 8, 0)
  defp term(<<89, rest::binary>>, acc), do: node(rest, acc, 4, 0)
  defp term(<<120, rest::binary>>, acc), do: node(rest, acc, 8, 0)
  defp term(<<90, len::16, rest::binary>>, acc), do: node(rest, acc, 0, 4 * len)

  # NEW_FUN_EXT: module, old index, old uniq and pid, then the free variables.
  defp term(
         <<112, _size::32, _arity, _uniq::binary-size(16), _index::32, free::32, rest::binary>>,
         acc
       ),
       do: {:ok, rest, 4 + free, %{acc | funs: acc.funs + 1}}

  # EXPORT_EXT: module, function, arity.
  defp term(<<113, rest::binary>>, acc), do: {:ok, rest, 3, %{acc | funs: acc.funs + 1}}
  defp term(_other, _acc), do: :error

  defp atom_name(<<118, n::16, name::binary-size(n), rest::binary>>), do: {:ok, :utf8, name, rest}
  defp atom_name(<<119, n::8, name::binary-size(n), rest::binary>>), do: {:ok, :utf8, name, rest}

  defp atom_name(<<100, n::16, name::binary-size(n), rest::binary>>),
    do: {:ok, :latin1, name, rest}

  defp atom_name(<<115, n::8, name::binary-size(n), rest::binary>>),
    do: {:ok, :latin1, name, rest}

  defp atom_name(_other), do: :error

  # Keyed by encoding too: the same bytes as latin1 and as utf8 are two different atoms.
  defp atom(name, encoding, rest, acc) do
    :erlang.binary_to_existing_atom(name, encoding)
    {:ok, rest, 0, acc}
  rescue
    ArgumentError -> {:ok, rest, 0, %{acc | atoms: MapSet.put(acc.atoms, {encoding, name})}}
  end

  defp node(binary, acc, before, after_creation) do
    with {:ok, encoding, name, rest} <- atom_name(binary),
         <<_::binary-size(^before), creation::32, _::binary-size(^after_creation), rest::binary>> <-
           rest,
         {:ok, rest, 0, acc} <- atom(name, encoding, rest, acc) do
      {:ok, rest, 0, %{acc | nodes: MapSet.put(acc.nodes, {encoding, name, creation})}}
    else
      _ -> :error
    end
  end
end
