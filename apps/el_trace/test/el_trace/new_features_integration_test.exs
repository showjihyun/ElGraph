defmodule ElTrace.NewFeaturesIntegrationTest do
  # 신규 구현 기능(오케스트레이션 등)이 ElTrace 관측과 연계되는지 검증한다.
  # 앱 싱글턴 Sessions를 공유하므로 직렬화한다.
  use ExUnit.Case, async: false

  alias ElGraph.Checkpointer.ETS
  alias ElGraph.{LLM, Orchestration}
  alias ElGraph.Test.ScriptedLLM

  setup do
    :ets.delete_all_objects(ElTrace.Sessions.table(ElTrace.Sessions))
    cp_pid = start_supervised!(ETS)
    %{cp: {ETS, ETS.config(cp_pid)}}
  end

  # 워커 노드 (원격 캡처).
  def research(_state, _ctx), do: %{messages: [LLM.assistant("research: found")]}

  describe "ElTrace observes a multi-agent orchestration run" do
    test "the supervisor run's checkpoint chain becomes a lifecycle timeline", %{cp: cp} do
      {:ok, llm} =
        ScriptedLLM.start_link([LLM.assistant("researcher"), LLM.assistant("DONE")])

      workers = [%{name: :researcher, description: "gathers facts", run: &__MODULE__.research/2}]
      graph = Orchestration.supervisor({ScriptedLLM, llm}, workers, [])

      {:ok, _final} =
        ElGraph.invoke(graph, %{messages: [LLM.user("go")]},
          checkpointer: cp,
          thread_id: "orch-1"
        )

      assert :ok = ElTrace.observe("orch-1", graph, cp)
      assert {:ok, events} = ElTrace.timeline("orch-1")

      # 멀티 superstep 실행 → 생애 타임라인(시작 → … → 완료).
      assert length(events) >= 2
      assert Enum.any?(events, &match?(%{kind: :start}, &1))
      assert Enum.any?(events, &match?(%{kind: :done}, &1))

      # 텍스트 렌더도 동작 (UI가 쓰는 경로).
      rendered = events |> ElTrace.Timeline.render()
      assert rendered =~ "done"
    end

    test "an observed orchestration thread can be forked (time-travel) from an early step", %{
      cp: cp
    } do
      {:ok, llm} =
        ScriptedLLM.start_link([
          LLM.assistant("researcher"),
          LLM.assistant("DONE"),
          # fork 분기가 재실행할 오케스트레이터 턴들
          LLM.assistant("DONE")
        ])

      workers = [%{name: :researcher, description: "gathers facts", run: &__MODULE__.research/2}]
      graph = Orchestration.supervisor({ScriptedLLM, llm}, workers, [])

      {:ok, _} =
        ElGraph.invoke(graph, %{messages: [LLM.user("go")]},
          checkpointer: cp,
          thread_id: "orch-2"
        )

      :ok = ElTrace.observe("orch-2", graph, cp)

      # step 0에서 새 thread로 분기 — 원본은 보존된다.
      assert {:ok, fork_id, _result} = ElTrace.fork("orch-2", 0, as: "orch-2-branch")
      assert {:ok, _} = ElTrace.timeline(fork_id)
      assert {:ok, _} = ElTrace.timeline("orch-2")
    end
  end

  describe "ElTrace.handoff_graph/0 (app-started singleton collector)" do
    test "reflects handoff telemetry emitted in the app collector" do
      :ok = ElTrace.Handoff.Collector.reset(ElTrace.Handoff.Collector)

      :telemetry.execute([:el_graph, :agent, :handoff], %{}, %{
        from: "researcher",
        to: "summarizer",
        signal: "research.done"
      })

      # graph/0 -> edges/0 is a GenServer.call that flushes the prior cast.
      assert %{nodes: nodes, edges: edges} = ElTrace.handoff_graph()
      assert "researcher" in nodes and "summarizer" in nodes
      assert %{from: "researcher", to: "summarizer", signal: "research.done"} in edges
    end
  end
end
