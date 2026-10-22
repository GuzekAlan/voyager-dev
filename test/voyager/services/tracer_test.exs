defmodule Voyager.Services.TracerTest do
  # async: false because these tests swap the global erpc impl and share the app's Tracer.
  use ExUnit.Case, async: false

  alias Voyager.Services.Tracer
  alias Voyager.Test.VoyagerAgentFixture

  setup do
    VoyagerAgentFixture.load!()

    prev_erpc = Application.get_env(:voyager, :erpc)
    Application.put_env(:voyager, :erpc, Voyager.Erpc.Impl)
    on_exit(fn -> Application.put_env(:voyager, :erpc, prev_erpc) end)

    Phoenix.PubSub.subscribe(Voyager.PubSub, Tracer.topic())
    on_exit(fn -> Tracer.stop(:ui) end)
    {:ok, session} = Tracer.create(:ui)
    %{session: session}
  end

  test "creates and closes the active session", %{session: %{id: id}} do
    assert_receive {:session_created, %{id: ^id, origin: :ui, save: false, status: :idle}}

    assert {:ok, %{id: new_id, origin: :mcp, save: true}} = Tracer.create(:mcp, save: true)
    refute new_id == id
    assert {%{id: ^new_id}, []} = Tracer.active()

    assert [%{id: ^new_id}] = Tracer.sessions()

    assert :ok = Tracer.close()
    assert_receive {:session_closed, ^new_id}
    assert {nil, []} = Tracer.active()
    assert [] = Tracer.sessions()
    assert {:error, :not_found} = Tracer.entries(new_id, 0, 10)
    assert {:error, :no_session} = configure()
    assert {:error, :no_session} = Tracer.start(:ui)
  end

  test "logs the configure, the events and the stop with their origins" do
    assert {:ok, %{id: id, status: :idle}} = configure(%{}, :mcp)

    assert_receive {:session_log, %{id: ^id},
                    [%{seq: 0, kind: :configured, origin: :mcp, node: node, config: _config}]}

    assert node == Node.self()

    assert {:ok, %{id: ^id, status: :running}} = Tracer.start(:ui)
    assert_receive {:session_log, %{status: :running}, [%{seq: 1, kind: :started, origin: :ui}]}

    Date.leap_year?(~D[2024-01-01])

    assert_receive {:session_log, %{events: 1},
                    [%{seq: 2, kind: :trace, type: :call, mfa: {Date, :leap_year?, 1}}]},
                   1_000

    assert :ok = Tracer.stop(:mcp)

    assert_receive {:session_log,
                    %{status: :stopped, stop_reason: :stopped, ended_at: %DateTime{}},
                    [
                      %{
                        seq: 3,
                        kind: :stopped,
                        origin: :mcp,
                        reason: :stopped,
                        events: 1,
                        dropped: 0
                      }
                    ]}

    assert {%{id: ^id, status: :stopped},
            [%{kind: :stopped}, %{kind: :trace}, %{kind: :started}, %{kind: :configured}]} =
             Tracer.active()

    assert {:ok,
            %{entries: [%{seq: 1, kind: :started}, %{seq: 2, kind: :trace}], truncated?: false}} =
             Tracer.entries(id, 1, 2)

    assert {:ok, %{entries: [], truncated?: false}} = Tracer.entries(id, 4, 10)
  end

  test "resumes a stopped session" do
    assert {:ok, %{id: id}} = configure(%{max_events: 1})
    assert {:ok, _session} = Tracer.start(:ui)
    Date.leap_year?(~D[2024-01-01])

    assert_receive {:session_log, %{id: ^id},
                    [%{kind: :stopped, origin: nil, reason: :event_limit}]}

    assert {:ok, %{id: ^id, status: :running}} = Tracer.start(:ui)
    Date.leap_year?(~D[2024-01-01])
    assert_receive {:session_log, %{id: ^id, events: 2}, [%{kind: :stopped}]}

    assert {_session, entries} = Tracer.active()

    assert Enum.map(entries, &{&1.seq, &1.kind}) == [
             {6, :stopped},
             {5, :trace},
             {4, :started},
             {3, :stopped},
             {2, :trace},
             {1, :started},
             {0, :configured}
           ]
  end

  test "returns the config errors" do
    assert {:error, %Ecto.Changeset{valid?: false}} = configure(%{module: nil})
    refute_receive {:session_log, _session, _entries}
  end

  test "resolves selected pids on the traced node" do
    attrs = %{module: "Elixir.Date", pids: ["<0.45.6>"], max_events: 1}
    assert {:error, :noconnection} = Tracer.configure(:other@nohost, attrs, :ui)
    refute_receive {:session_log, _session, _entries}
  end

  test "resolves the pids again on start" do
    assert {:ok, _session} = configure()
    :sys.replace_state(Tracer, &put_in(&1.session.node, :other@nohost))
    assert {:error, :noconnection} = Tracer.start(:ui)
  end

  test "refuses to start without a config" do
    assert {:error, :not_configured} = Tracer.start(:ui)
  end

  test "refuses to change the session while running" do
    assert {:ok, _session} = configure()
    assert {:ok, _session} = Tracer.start(:ui)
    assert {:error, :busy} = Tracer.start(:ui)
    assert {:error, :busy} = configure()
    assert {:error, :busy} = Tracer.create(:ui)
    assert {:error, :busy} = Tracer.close()
  end

  test "ends a disconnected session when its tracer goes down" do
    assert {:ok, _session} = configure()
    assert {:ok, %{tracer: tracer}} = Tracer.start(:ui)
    assert :ok = Tracer.disconnected()
    _ = :sys.get_state(Tracer)
    Process.exit(tracer, :noconnection)

    assert_receive {:session_log, %{stop_reason: :disconnected},
                    [%{kind: :stopped, origin: nil, reason: :disconnected}]}
  end

  test "ends the session when the remote tracer dies" do
    assert {:ok, _session} = configure()
    assert {:ok, %{tracer: tracer}} = Tracer.start(:ui)
    Process.exit(tracer, :kill)

    assert_receive {:session_log, _session, [%{kind: :stopped, reason: {:tracer_down, :killed}}]}
  end

  test "keeps every control entry but only the newest events", %{session: session} do
    assert {:ok, _session} = configure(%{max_events: 501})
    assert {:ok, _session} = Tracer.start(:ui)

    for _ <- 1..501, do: Date.leap_year?(~D[2024-01-01])

    assert_receive {:session_log, %{events: 501}, [%{kind: :stopped}]}
    assert {_session, [%{kind: :stopped} | entries]} = Tracer.active()
    assert [%{kind: :started}, %{kind: :configured}] = Enum.take(entries, -2)
    assert length(entries) == 502

    assert {:ok, %{entries: [%{seq: 0}, %{seq: 1}, %{seq: 3, kind: :trace}], truncated?: true}} =
             Tracer.entries(session.id, 0, 3)

    assert {:ok, %{entries: [%{seq: 3}], truncated?: false}} = Tracer.entries(session.id, 3, 1)
  end

  test "logs batches dropped here and by the agent" do
    assert {:ok, _session} = configure()
    assert {:ok, %{tracer: tracer}} = Tracer.start(:ui)

    :sys.suspend(Tracer)
    for _ <- 1..1_005, do: send(Tracer, {:voyager_trace_events, tracer, [%{}], 0})
    :sys.resume(Tracer)

    assert_receive {:session_log, %{events: 0, dropped: 1}, [%{seq: 2, kind: :dropped, count: 1}]}
    assert_receive {:session_log, %{events: 0, dropped: 4}, [%{seq: 5, kind: :dropped, count: 1}]}
    assert_receive {:session_log, %{events: 1_001, dropped: 4}, [%{seq: 1_006, kind: :trace}]}

    send(Tracer, {:voyager_trace_events, tracer, [%{}], 2})

    assert_receive {:session_log, %{dropped: 6},
                    [%{seq: 1_007, kind: :dropped, count: 2}, %{seq: 1_008, kind: :trace}]}
  end

  test "returns the agent's refusal on start" do
    assert {:ok, _session} = configure(%{module: "Elixir.Voyager.NoSuchModule"})
    assert {:error, :unknown_function} = Tracer.start(:ui)
    refute_receive {:session_log, %{status: :running}, _entries}
  end

  test "emits telemetry without the traced function" do
    events = [
      [:voyager, :trace, :start],
      [:voyager, :trace, :start_failed],
      [:voyager, :trace, :stop]
    ]

    handler = {__MODULE__, self()}
    :telemetry.attach_many(handler, events, &__MODULE__.forward_telemetry/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, _session} = configure()
    assert {:ok, _session} = Tracer.start(:ui)
    assert :ok = Tracer.stop(:mcp)
    assert {:ok, _session} = configure(%{module: "Elixir.Voyager.NoSuchModule"})
    assert {:error, _reason} = Tracer.start(:mcp)

    assert_receive {:telemetry, [:voyager, :trace, :start], _,
                    %{origin: :ui, processes: :pids, capture: :args} = meta}

    refute Map.has_key?(meta, :module)

    assert_receive {:telemetry, [:voyager, :trace, :stop],
                    %{events: 0, dropped: 0, duration_ms: _}, %{origin: :ui, reason: :stopped}}

    assert_receive {:telemetry, [:voyager, :trace, :start_failed], _, %{origin: :mcp}}
  end

  def forward_telemetry(event, measurements, metadata, pid),
    do: send(pid, {:telemetry, event, measurements, metadata})

  defp configure(overrides \\ %{}, origin \\ :ui) do
    attrs =
      Map.merge(
        %{
          module: "Elixir.Date",
          function: "leap_year?",
          arity: 1,
          pids: [Voyager.Pid.format(self(), :distribution)],
          capture: :args,
          max_events: 1_000,
          max_time_ms: 5_000,
          budget: 50
        },
        overrides
      )

    Tracer.configure(Node.self(), attrs, origin)
  end
end
