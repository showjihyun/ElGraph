defmodule ElTraceWeb.HandoffLiveTest do
  # 앱 싱글턴 핸드오프 컬렉터(전역 상태)를 공유하므로 직렬화한다.
  use ElTraceWeb.ConnCase, async: false

  alias ElTrace.Handoff.Collector

  setup do
    Collector.reset(Collector)
    on_exit(fn -> Collector.reset(Collector) end)
    :ok
  end

  defp seed(from, to, signal) do
    :telemetry.execute([:el_graph, :agent, :handoff], %{}, %{from: from, to: to, signal: signal})
    # cast로 모으므로 read(call)로 flush될 때까지 동기적으로 보장
    Collector.edges(Collector)
  end

  test "핸드오프 엣지와 DOT 소스를 보여준다", %{conn: conn} do
    seed("researcher", "summarizer", "research.done")

    {:ok, _view, html} = live(conn, ~p"/handoff")

    assert html =~ "researcher"
    assert html =~ "summarizer"
    assert html =~ "research.done"
    # 서버사이드 SVG 그래프가 인라인 렌더된다
    assert html =~ "<svg"
    assert html =~ "<marker"
    assert html =~ "class=\"edge\""
    # Graphviz DOT 소스도 함께
    assert html =~ "digraph"
    assert html =~ "-&gt;" or html =~ "->"
  end

  test "핸드오프가 없으면 빈 상태 안내를 보여준다", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/handoff")

    assert html =~ "아직 핸드오프가 없습니다"
    assert html =~ "0"
  end

  test "refresh 버튼이 새 엣지를 반영한다", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/handoff")
    refute html =~ "planner"

    seed("planner", "researcher", "plan.ready")

    html = render_click(view, "refresh")

    assert html =~ "planner"
    assert html =~ "researcher"
    assert html =~ "plan.ready"
  end
end
