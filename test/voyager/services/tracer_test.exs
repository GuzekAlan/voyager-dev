defmodule Voyager.Services.TracerTest do
  # async: false because these tests swap the global erpc impl and share the app's Tracer.
  use ExUnit.Case, async: false

  alias Voyager.Services.Tracer
  alias Voyager.Test.VoyagerAgentFixture

  @limits %{max_events: 1_000, max_time_ms: 5_000, budget: 50}

  setup do
    VoyagerAgentFixture.load!()

    prev_erpc = Application.get_env(:voyager, :erpc)
    Application.put_env(:voyager, :erpc, Voyager.Erpc.Impl)
    on_exit(fn -> Application.put_env(:voyager, :erpc, prev_erpc) end)

    Phoenix.PubSub.subscribe(Voyager.PubSub, Tracer.topic())
    on_exit(fn -> Tracer.stop() end)
    :ok
  end

  test "broadcasts the session, its events and the stop" do
    assert {:ok, %{id: id, origin: :ui, status: :running}} = start()
    assert_receive {:tracing_started, %{id: ^id}}

    Date.leap_year?(~D[2024-01-01])

    assert_receive {:trace_events, %{id: ^id, events: 1},
                    [%{id: 0, type: :call, mfa: {Date, :leap_year?, 1}}]},
                   1_000

    assert :ok = Tracer.stop()

    assert_receive {:tracing_ended,
                    %{id: ^id, status: :ended, stop_reason: :stopped, ended_at: %DateTime{}}}

    assert {%{id: ^id, status: :ended}, [%{id: 0}]} = Tracer.current()
  end

  test "refuses a second session while one runs" do
    assert {:ok, _session} = start()
    assert {:error, :busy} = start()
  end

  test "reports the agent's limit as the stop reason" do
    assert {:ok, %{id: id}} = start(%{@limits | max_events: 1})

    Date.leap_year?(~D[2024-01-01])

    assert_receive {:tracing_ended, %{id: ^id, stop_reason: :event_limit, events: 1}}
  end

  test "reports the caller's stop reason" do
    assert {:ok, %{id: id}} = start()
    assert :ok = Tracer.stop(:disconnected)
    assert_receive {:tracing_ended, %{id: ^id, stop_reason: :disconnected}}
  end

  test "ends the session when the remote tracer dies" do
    assert {:ok, %{id: id, tracer: tracer}} = start()
    Process.exit(tracer, :kill)
    assert_receive {:tracing_ended, %{id: ^id, stop_reason: {:tracer_down, :killed}}}
  end

  test "keeps only the newest events" do
    assert {:ok, %{id: id}} = start(%{@limits | max_events: 501})

    for _ <- 1..501, do: Date.leap_year?(~D[2024-01-01])

    assert_receive {:tracing_ended, %{id: ^id, events: 501}}
    assert {_session, [%{id: 500} | _] = events} = Tracer.current()
    assert length(events) == 500
  end

  test "returns the agent's validation error" do
    assert {:error, {:invalid, :capture}} =
             Tracer.start(Node.self(), spec(capture: :all), @limits, :mcp)

    refute_receive {:tracing_started, _session}
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

    assert {:ok, _session} = start()
    assert :ok = Tracer.stop()
    assert {:error, _reason} = Tracer.start(Node.self(), spec(capture: :all), @limits, :mcp)

    assert_receive {:telemetry, [:voyager, :trace, :start], _,
                    %{origin: :ui, processes: :pids, capture: :args, match_spec?: false} = meta}

    refute Map.has_key?(meta, :module)

    assert_receive {:telemetry, [:voyager, :trace, :stop],
                    %{events: 0, dropped: 0, duration_ms: _}, %{origin: :ui, reason: :stopped}}

    assert_receive {:telemetry, [:voyager, :trace, :start_failed], _, %{origin: :mcp}}
  end

  def forward_telemetry(event, measurements, metadata, pid),
    do: send(pid, {:telemetry, event, measurements, metadata})

  defp start(limits \\ @limits), do: Tracer.start(Node.self(), spec(), limits, :ui)

  defp spec(overrides \\ []) do
    Enum.into(overrides, %{
      module: "Elixir.Date",
      function: "leap_year?",
      arity: 1,
      processes: [self()],
      capture: :args,
      scope: :global,
      return_trace: false,
      match_spec: :undefined
    })
  end
end
