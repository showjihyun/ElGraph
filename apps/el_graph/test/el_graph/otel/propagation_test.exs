defmodule ElGraph.OTel.PropagationTest do
  use ExUnit.Case, async: true

  # OTel 컨텍스트가 병렬 fan-out(별도 Task)으로도 전파되는지 검증한다 (트렌드 보고서 Tier 1.4).
  # SDK/exporter 없이 OpenTelemetry.Ctx 값 전파로 직접 확인 — process-dict 기반이라 async 안전.

  defmodule Probe do
    # 실행기 프로세스의 현재 OTel 컨텍스트에 값을 심는다 (인라인 단일 노드 → 실행기 프로세스).
    def setup(_state, _ctx) do
      OpenTelemetry.Ctx.set_value(:el_graph_probe, "propagated")
      %{}
    end

    # 병렬 Task 안에서 실행된다 — 전파가 되면 부모가 심은 값이 보인다.
    def read_a(_state, _ctx), do: %{a_saw: OpenTelemetry.Ctx.get_value(:el_graph_probe, :none)}
    def read_b(_state, _ctx), do: %{b_saw: OpenTelemetry.Ctx.get_value(:el_graph_probe, :none)}
  end

  test "OTel context propagates into parallel fan-out tasks" do
    graph =
      ElGraph.new()
      |> ElGraph.state(:a_saw)
      |> ElGraph.state(:b_saw)
      |> ElGraph.add_node(:setup, &Probe.setup/2)
      |> ElGraph.add_node(:a, &Probe.read_a/2)
      |> ElGraph.add_node(:b, &Probe.read_b/2)
      |> ElGraph.add_edge(:setup, :a)
      |> ElGraph.add_edge(:setup, :b)
      |> ElGraph.compile(entry: :setup)

    assert {:ok, %{a_saw: "propagated", b_saw: "propagated"}} = ElGraph.invoke(graph, %{})
  end
end
