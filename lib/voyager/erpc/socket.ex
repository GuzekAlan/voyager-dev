defmodule Voyager.Erpc.Socket do
  @moduledoc """
  `Voyager.Erpc` implementation over `Voyager.Services.DistClient`. Raises the
  same exceptions as `:erpc.call/5`, so `Voyager.Erpc.format_error/2` applies
  unchanged.
  """

  @behaviour Voyager.Erpc

  alias Voyager.Services.DistClient

  @impl Voyager.Erpc
  def call(node, mod, fun, args), do: call(node, mod, fun, args, :infinity)

  @impl Voyager.Erpc
  def call(node, mod, fun, args, %{timeout: timeout}), do: call(node, mod, fun, args, timeout)

  def call(node, mod, fun, args, timeout) do
    case DistClient.whereis(node) do
      nil -> :erlang.error({:erpc, :noconnection})
      client -> client |> DistClient.call(mod, fun, args, timeout) |> result()
    end
  end

  defp result({:down, {_ref, :return, value}}), do: value
  defp result({:down, {_ref, :throw, value}}), do: throw(value)
  defp result({:down, {_ref, :exit, reason}}), do: exit({:exception, reason})

  defp result({:down, {_ref, :error, reason, stack}}),
    do: :erlang.error({:exception, reason, stack})

  defp result({:down, {_ref, :error, {:erpc, _} = reason}}), do: :erlang.error(reason)
  defp result({:down, :noconnection}), do: :erlang.error({:erpc, :noconnection})
  defp result({:down, reason}), do: exit({:signal, reason})
  defp result({:spawn_error, reason}), do: :erlang.error({:erpc, reason})
  defp result(:timeout), do: :erlang.error({:erpc, :timeout})
end
