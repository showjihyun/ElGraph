defmodule ElGraph.ExecutorResumeFromTest do
  use ExUnit.Case, async: true

  alias ElGraph.{Checkpoint, Executor, TestNodes}
  alias ElGraph.Checkpointer.ETS

  setup do
    pid = start_supervised!(ETS)
    %{checkpointer: {ETS, ETS.config(pid)}}
  end

  defp seq_graph do
    ElGraph.new()
    |> ElGraph.state(:result)
    |> ElGraph.add_node(:greet, &TestNodes.greet/2)
    |> ElGraph.add_node(:shout, &TestNodes.shout/2)
    |> ElGraph.add_edge(:greet, :shout)
    |> ElGraph.compile(entry: :greet)
  end

  # :shout 직전에서 멈춘 체크포인트(state: %{result: "hello"}, next: [:shout])를 확보한다.
  defp paused_checkpoint(graph, cp, thread_id) do
    {mod, config} = cp

    assert {:interrupted, %{step: 1}} =
             ElGraph.invoke(graph, %{},
               checkpointer: cp,
               thread_id: thread_id,
               interrupt_before: [:shout]
             )

    {:ok, checkpoint} = mod.get(config, thread_id, :latest)
    checkpoint
  end

  describe "resume_from/3 (time-travel / fork 진입점, SPEC §3.5)" do
    test "임의 체크포인트를 새 thread로 분기 실행하고 원본은 보존한다", %{
      checkpointer: {mod, config} = cp
    } do
      graph = seq_graph()
      checkpoint = paused_checkpoint(graph, cp, "orig")

      # 같은 분기점에서 state만 바꿔 새 thread로 resume_from → fork.
      forked = %{checkpoint | thread_id: "fork", state: %{result: "bonjour"}}

      assert {:ok, %{result: "BONJOUR"}} =
               Executor.resume_from(graph, forked, checkpointer: cp, thread_id: "fork")

      # 원본 thread는 그대로 멈춰 있다 — state가 여전히 "hello"(미실행)면 :shout이 돌지 않았다.
      assert {:ok, %Checkpoint{state: %{result: "hello"}}} = mod.get(config, "orig", :latest)

      # fork thread는 자기만의 완료 체크포인트를 가진다.
      assert {:ok, %Checkpoint{state: %{result: "BONJOUR"}}} = mod.get(config, "fork", :latest)
    end

    test "checkpointer 없이도 순수 분기 실행이 동작한다(in-memory fork)", %{checkpointer: cp} do
      graph = seq_graph()
      checkpoint = paused_checkpoint(graph, cp, "src")

      # checkpointer 옵션 없이 분기점 상태에서 그대로 이어 실행한다.
      assert {:ok, %{result: "HELLO"}} = Executor.resume_from(graph, checkpoint, [])
    end
  end
end
