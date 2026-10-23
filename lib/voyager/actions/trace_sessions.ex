defmodule Voyager.Actions.TraceSessions do
  @moduledoc "Write actions for saved tracing sessions."

  import Ecto.Query

  alias Voyager.Queries.TraceSessions, as: TraceSessionQueries
  alias Voyager.Repo
  alias Voyager.Schemas.TraceSession

  @spec create(map()) :: {:ok, TraceSession.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs), do: %TraceSession{} |> TraceSession.changeset(attrs) |> Repo.insert()

  @doc "Deletes the session and its entries."
  @spec delete(integer()) :: {:ok, TraceSession.t()} | {:error, :not_found}
  def delete(id) do
    case TraceSessionQueries.get(id) do
      nil -> {:error, :not_found}
      session -> Repo.delete(session)
    end
  end

  @doc """
  Run on boot: sessions left `running` are stopped with reason `interrupted`,
  since the remote tracer stops when Voyager dies.
  """
  @spec interrupt_running() :: :ok
  def interrupt_running do
    TraceSession
    |> where(status: :running)
    |> Repo.update_all(set: [status: :stopped, stop_reason: "interrupted"])

    :ok
  end

  @doc "How a `Voyager.Services.Tracer.stop_reason()` is stored."
  @spec stop_reason_text(term()) :: String.t() | nil
  def stop_reason_text(nil), do: nil
  def stop_reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  def stop_reason_text(reason), do: inspect(reason)
end
