defmodule ElTraceTest do
  # 앱 싱글턴 Sessions를 공유하므로 직렬화한다.
  use ExUnit.Case, async: false

  alias ElGraph.Checkpointer.ETS
  alias ElTrace.TestGraphs

  setup do
    :ets.delete_all_objects(ElTrace.Sessions.table(ElTrace.Sessions))
    cp_pid = start_supervised!(ETS)
    %{cp: {ETS, ETS.config(cp_pid)}}
  end

  describe "observe/4 + timeline/1" do
    test "observe registers a thread that timeline can read", %{cp: cp} do
      graph = TestGraphs.approval_graph()
      {:interrupted, _} = ElGraph.invoke(graph, %{}, checkpointer: cp, thread_id: "obs-1")

      assert :ok = ElTrace.observe("obs-1", graph, cp)
      assert {:ok, events} = ElTrace.timeline("obs-1")
      assert Enum.any?(events, &match?(%{kind: :interrupt, node: :approve}, &1))
    end

    test "timeline returns :error for an unobserved thread" do
      assert :error = ElTrace.timeline("unknown")
    end

    test "observe records fork lineage via :parent", %{cp: cp} do
      graph = TestGraphs.approval_graph()
      ElGraph.invoke(graph, %{}, checkpointer: cp, thread_id: "parent-t")

      assert :ok = ElTrace.observe("child-t", graph, cp, parent: "parent-t")

      assert {:ok, %{parent: "parent-t"}} =
               ElTrace.Sessions.get(ElTrace.Sessions.table(ElTrace.Sessions), "child-t")
    end
  end

  describe "fork/3 — 여기서 분기 (time-travel)" do
    setup %{cp: cp} do
      graph = TestGraphs.approval_graph()

      {:interrupted, %{step: step}} =
        ElGraph.invoke(graph, %{}, checkpointer: cp, thread_id: "src")

      :ok = ElTrace.observe("src", graph, cp)
      %{graph: graph, step: step}
    end

    test "branches a new observed thread from a step and preserves the source", %{step: step} do
      assert {:ok, fork_id, _result} = ElTrace.fork("src", step)
      assert fork_id == "src-fork-#{step}"

      table = ElTrace.Sessions.table(ElTrace.Sessions)
      assert {:ok, %{parent: "src"}} = ElTrace.Sessions.get(table, fork_id)

      # 원본은 보존된다 — 여전히 인터럽트 상태.
      assert {:ok, src_events} = ElTrace.timeline("src")
      assert Enum.any?(src_events, &match?(%{kind: :interrupt}, &1))
    end

    test "fork then reject-resume drives the branch to a different outcome", %{
      cp: cp,
      graph: graph,
      step: step
    } do
      {:ok, fork_id, {:interrupted, _}} = ElTrace.fork("src", step, as: "src-거절")

      assert {:ok, %{result: "거절"}} =
               ElGraph.resume(graph, checkpointer: cp, thread_id: fork_id, resume: "거절")

      {:ok, fork_events} = ElTrace.timeline(fork_id)
      assert Enum.any?(fork_events, &match?(%{kind: :done}, &1))
    end

    test "unknown source returns :error" do
      assert :error = ElTrace.fork("missing", 1)
    end

    test "fork from a non-existent step returns an error and registers no junk session" do
      assert {:error, {:no_checkpoint, "src", 999}} = ElTrace.fork("src", 999, as: "src-bad")
      assert :error = ElTrace.Sessions.get(ElTrace.Sessions.table(ElTrace.Sessions), "src-bad")
    end
  end
end
