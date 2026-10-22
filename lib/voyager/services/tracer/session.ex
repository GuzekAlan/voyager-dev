defmodule Voyager.Services.Tracer.Session do
  @moduledoc "The `Voyager.Services.Tracer` session: a node and config, plus the state of its runs. `seq` numbers the next log entry."

  alias Voyager.Services.Tracer.Config

  @enforce_keys [:id, :origin, :created_at]
  defstruct [
    :id,
    :origin,
    :created_at,
    :node,
    :config,
    :tracer,
    :stop_reason,
    :started_at,
    :ended_at,
    save: false,
    status: :idle,
    events: 0,
    dropped: 0,
    seq: 0
  ]

  @type t :: %__MODULE__{
          id: pos_integer(),
          origin: Voyager.Services.Tracer.origin(),
          save: boolean(),
          created_at: DateTime.t(),
          node: node() | nil,
          config: Config.t() | nil,
          tracer: pid() | nil,
          status: :idle | :running | :stopped,
          stop_reason: term(),
          events: non_neg_integer(),
          dropped: non_neg_integer(),
          seq: non_neg_integer(),
          started_at: DateTime.t() | nil,
          ended_at: DateTime.t() | nil
        }
end
