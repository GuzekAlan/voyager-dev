defmodule Voyager.Pid do
  @moduledoc """
  Converts PIDs to and from their `"<X.Y.Z>"` string representation and
  formats them for display. The display format and the connected node's id
  are cached in `:persistent_term`, so formatting never makes a call.
  """

  alias Voyager.Erpc
  alias Voyager.Settings

  @format_key {__MODULE__, :format}
  @node_id_key {__MODULE__, :node_id}
  @node_pid_key {__MODULE__, :node_pid}
  @formats [:distribution, :local]

  @spec parse(String.t()) :: pid() | nil
  def parse(pid_str) when is_binary(pid_str) do
    pid_str = String.trim_leading(pid_str, "#PID")
    list_to_pid(pid_str) || parse_connected(pid_str)
  end

  @doc "The `N` of the connected node's `<N.X.Y>` pids, cached by `put_node/1`."
  @spec cached_node_id() :: String.t() | nil
  def cached_node_id, do: :persistent_term.get(@node_id_key, nil)

  @spec put_node(node() | nil) :: :ok
  def put_node(nil) do
    :persistent_term.put(@node_pid_key, nil)
    :persistent_term.put(@node_id_key, nil)
  end

  def put_node(node) do
    pid = node_pid(node)
    :persistent_term.put(@node_pid_key, pid)
    :persistent_term.put(@node_id_key, pid && node_id(pid))
  end

  @doc """
  The display format cached by `load_format/0` or `put_format/1`;
  `:distribution` until either runs.
  """
  @spec cached_format() :: :distribution | :local
  def cached_format, do: :persistent_term.get(@format_key, :distribution)

  @doc """
  Reads the PID format setting into the cache. Unknown values fall back to
  `:distribution`.
  """
  @spec load_format() :: :ok
  def load_format do
    :pid_format
    |> Settings.get(:distribution)
    |> normalize_format()
    |> put_format()
  end

  @spec put_format(:distribution | :local) :: :ok
  def put_format(format) when format in @formats do
    :persistent_term.put(@format_key, format)
  end

  @doc """
  Formats a PID for display. Omitting the format uses `cached_format/0`.
  `:local` shortens only the connected node's pids.

      iex> Voyager.Pid.format("<123.23.423>", :distribution)
      "<123.23.423>"
  """
  @spec format(pid() | String.t(), :distribution | :local) :: String.t()
  def format(pid, format \\ cached_format()) when format in @formats do
    pid
    |> pid_to_string()
    |> maybe_localize(format)
  end

  @doc "An `:inspect_fun` that renders every pid, however deeply nested, via `format/1`."
  @spec inspect_fun(term(), Inspect.Opts.t()) :: Inspect.Algebra.t()
  def inspect_fun(pid, _opts) when is_pid(pid), do: "#PID" <> format(pid)
  def inspect_fun(term, opts), do: Inspect.inspect(term, opts)

  defp list_to_pid(pid_str) do
    :erlang.list_to_pid(String.to_charlist(pid_str))
  rescue
    ArgumentError -> nil
  end

  defp node_pid(node) do
    case Erpc.safe_call(node, :erlang, :self, []) do
      {:ok, pid} when is_pid(pid) -> pid
      _error -> nil
    end
  end

  # Any pid of the node, printed here, carries the `N` this node gives it.
  defp node_id(pid) do
    [_prefix, id] = Regex.run(~r/^<(\d+)\./, format(pid, :distribution))
    id
  end

  # Without distribution `list_to_pid/1` rejects remote pids, so rebuild one from
  # the connected node's name and creation, taken from a pid it returned.
  defp parse_connected(pid_str) do
    with %{} = node <- connected_node(),
         [_, id, number, serial] <- Regex.run(~r/^<(\d+)\.(\d+)\.(\d+)>$/, pid_str),
         true <- id == node.id do
      :erlang.binary_to_term(
        <<131, 88, node.atom::binary, String.to_integer(number)::32,
          String.to_integer(serial)::32, node.creation::32>>
      )
    else
      _ -> nil
    end
  end

  defp connected_node do
    with pid when is_pid(pid) <- :persistent_term.get(@node_pid_key, nil),
         <<131, 88, rest::binary>> <- :erlang.term_to_binary(pid) do
      atom_size = byte_size(rest) - 12
      <<atom::binary-size(^atom_size), _number::32, _serial::32, creation::32>> = rest
      %{atom: atom, creation: creation, id: cached_node_id()}
    end
  end

  defp normalize_format(format) when format in @formats, do: format
  defp normalize_format(_format), do: :distribution

  defp pid_to_string(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()
  defp pid_to_string(pid) when is_binary(pid), do: pid

  defp maybe_localize(pid_string, :distribution), do: pid_string

  defp maybe_localize(pid_string, :local) do
    node_id = cached_node_id()

    if node_id && Regex.match?(~r/^<\d+\.\d+\.\d+>$/, pid_string) do
      String.replace_prefix(pid_string, "<#{node_id}.", "<0.")
    else
      pid_string
    end
  end
end
