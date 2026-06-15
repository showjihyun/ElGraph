defmodule ElGraph.Skills.HandoffTelemetryTest do
  use ExUnit.Case, async: true

  alias ElGraph.Signal
  alias ElGraph.Skills.SignalReAct

  setup do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      "handoff-test-#{inspect(ref)}",
      [:el_graph, :agent, :handoff],
      fn event, measurements, metadata, _config ->
        send(parent, {:handoff, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("handoff-test-#{inspect(ref)}") end)
    :ok
  end

  # 핸드오프 이벤트는 전역 telemetry라, 이 테스트 고유의 reply_tag/source를 써서 다른 async
  # 테스트의 emit과 섞이지 않게 한다(필터 디스크리미네이터).
  defp skill_opts do
    [route: "ht.*", input_key: :report, reply_tag: :ht_target]
  end

  defp context, do: %{opts: []}

  test "emits a handoff edge when a matching signal came from another agent" do
    signal = %Signal{type: "ht.done", source: "ht_researcher", data: %{report: "r"}}

    assert {:run, _} = SignalReAct.__handle_signal__(skill_opts(), signal, context())

    assert_receive {:handoff, [:el_graph, :agent, :handoff], %{},
                    %{from: "ht_researcher", to: "ht_target", signal: "ht.done"}}
  end

  test "emits no handoff when the source is nil (external/user signal)" do
    signal = %Signal{type: "ht.done", source: nil, data: %{report: "r"}}

    assert {:run, _} = SignalReAct.__handle_signal__(skill_opts(), signal, context())

    refute_receive {:handoff, _, _, %{to: "ht_target"}}, 50
  end

  test "emits no handoff when the route does not match" do
    signal = %Signal{type: "other.event", source: "ht_researcher", data: %{report: "r"}}

    assert :ignore = SignalReAct.__handle_signal__(skill_opts(), signal, context())

    refute_receive {:handoff, _, _, %{to: "ht_target"}}, 50
  end
end
