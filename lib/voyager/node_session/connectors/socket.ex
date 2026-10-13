defmodule Voyager.NodeSession.Connectors.Socket do
  @moduledoc """
  `Voyager.NodeSession.Connector` that reaches the node through
  `Voyager.Services.DistClient`, so this VM never joins Erlang distribution.
  """

  @behaviour Voyager.NodeSession.Connector

  alias Voyager.Services.DistClient
  alias Voyager.Services.Distribution

  @epmd_timeout 5_000

  @impl true
  def name, do: :socket

  @impl true
  def connect(node_name, cookie, opts) do
    with {:ok, name, host} <- Distribution.split_node_name(node_name),
         address = Distribution.host_address(host),
         {:ok, port} <- epmd_port(name, address),
         node = String.to_atom(node_name),
         {:ok, client} <-
           DistClient.start(
             node: node,
             address: address,
             port: port,
             cookie: cookie,
             name_type: Keyword.get(opts, :name_type, :longnames)
           ) do
      {:ok, node, %{client: client, monitor: Process.monitor(client)}}
    end
  end

  @impl true
  def disconnect(_node, %{client: client, monitor: monitor}) do
    Process.demonitor(monitor, [:flush])
    DistClient.stop(client)
  end

  @impl true
  def subscriptions, do: []

  @impl true
  def teardown?({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor}), do: true
  def teardown?(_msg, _meta), do: false

  defp epmd_port(name, address) do
    case :erl_epmd.port_please(String.to_charlist(name), address, @epmd_timeout) do
      {:port, port, _version} -> {:ok, port}
      :noport -> {:error, :node_not_registered}
      {:error, reason} -> {:error, {:epmd_error, reason}}
      other -> {:error, {:epmd_error, other}}
    end
  end
end
