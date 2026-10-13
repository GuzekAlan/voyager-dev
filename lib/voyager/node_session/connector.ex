defmodule Voyager.NodeSession.Connector do
  @moduledoc """
  Behaviour for a `Voyager.NodeSession` connection strategy.
  """

  @typedoc "Connector-specific state stored alongside the session."
  @type meta :: map()

  @callback name() :: atom()

  @callback connect(node_name :: String.t(), cookie :: String.t(), opts :: keyword()) ::
              {:ok, node(), meta()} | {:error, term()}

  @callback disconnect(node(), meta()) :: :ok

  @doc """
  PubSub topics the session should subscribe to while connected.
  """
  @callback subscriptions() :: [String.t()]

  @doc """
  Whether an incoming process message means this connector's transport has
  already gone away. When it returns `true`, `NodeSession` calls `disconnect/2`
  to release what is left of the transport and drops the session.
  """
  @callback teardown?(msg :: term(), meta()) :: boolean()
end
