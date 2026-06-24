defmodule ElTraceWeb.TimelineLiveTest do
  # 앱 싱글턴 Sessions와 전역 텔레메트리 핸들러를 공유하므로 직렬화한다.
  use ElTraceWeb.ConnCase, async: false

  alias ElGraph.Checkpointer.ETS
  alias ElTrace.{Sessions, Telemetry, TestGraphs}

  setup do
    Telemetry.attach()
    on_exit(&Telemetry.detach/0)

    table = Sessions.table(Sessions)
    :ets.delete_all_objects(table)

    cp_pid = start_supervised!(ETS)
    %{table: table, cp: {ETS, ETS.config(cp_pid)}}
  end

  defp seed_interrupt(cp, table, tid) do
    graph = TestGraphs.approval_graph()
    {:interrupted, _} = ElGraph.invoke(graph, %{}, checkpointer: cp, thread_id: tid)
    Sessions.register(table, tid, graph, cp)
    graph
  end

  test "빈 레지스트리면 안내 문구를 보여준다", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/")
    assert html =~ "ElTrace"
    assert html =~ "등록된 실행이 없습니다"
  end

  describe "타임라인 렌더 (#1 인터럽트 가시성·#2 thread 생애)" do
    test "선택한 thread의 인터럽트(노드·payload)와 액션 버튼을 보여준다", %{
      conn: conn,
      cp: cp,
      table: table
    } do
      seed_interrupt(cp, table, "t-view")

      {:ok, lv, _} = live(conn, ~p"/")
      html = lv |> element("button.session", "t-view") |> render_click()

      assert html =~ "interrupt"
      assert html =~ "approve"
      assert html =~ "name?"
      assert html =~ "승인"
      assert html =~ "거절"
      assert html =~ "여기서 분기"
    end

    test "a non-integer branch step is ignored, not a crash", %{conn: conn, cp: cp, table: table} do
      seed_interrupt(cp, table, "t-badstep")

      {:ok, lv, _} = live(conn, ~p"/")
      render_hook(lv, "select", %{"thread" => "t-badstep"})

      # 위조된 클라이언트 파라미터 — 무시돼야 하고 LiveView를 죽이면 안 된다.
      render_hook(lv, "branch", %{"step" => "not-a-number"})

      assert Process.alive?(lv.pid)
      assert render(lv) =~ "ElTrace"
    end
  end

  describe "승인/거절 (resume)" do
    test "승인하면 thread가 완료(done)까지 진행된다", %{conn: conn, cp: cp, table: table} do
      seed_interrupt(cp, table, "t-approve")

      {:ok, lv, _} = live(conn, ~p"/")
      lv |> element("button.session", "t-approve") |> render_click()

      lv |> element("button.btn-approve") |> render_click()
      html = render_async(lv)

      assert html =~ "done"
    end
  end

  describe "여기서 분기 (#4 time-travel)" do
    test "인터럽트 step에서 분기하면 fork 세션이 목록에 뜬다", %{conn: conn, cp: cp, table: table} do
      graph = TestGraphs.approval_graph()
      {:interrupted, _} = ElGraph.invoke(graph, %{}, checkpointer: cp, thread_id: "t-branch")

      {:ok, _} =
        ElGraph.resume(graph, checkpointer: cp, thread_id: "t-branch", resume: "approved")

      Sessions.register(table, "t-branch", graph, cp)

      {:ok, lv, _} = live(conn, ~p"/")
      lv |> element("button.session", "t-branch") |> render_click()

      lv |> element(".event.interrupt button.btn-branch") |> render_click()
      html = render_async(lv)

      assert html =~ "t-branch-fork-"
      assert html =~ "⑂ from t-branch"
    end
  end
end
