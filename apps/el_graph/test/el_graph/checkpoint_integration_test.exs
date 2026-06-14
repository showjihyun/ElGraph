defmodule ElGraph.CheckpointIntegrationTest do
  use ExUnit.Case, async: true

  alias ElGraph.{Checkpoint, Reducers, TestNodes}
  alias ElGraph.Checkpointer.ETS

  setup do
    pid = start_supervised!(ETS)
    %{checkpointer: {ETS, ETS.config(pid)}}
  end

  defp sequential_graph do
    ElGraph.new()
    |> ElGraph.state(:result)
    |> ElGraph.add_node(:greet, &TestNodes.greet/2)
    |> ElGraph.add_node(:shout, &TestNodes.shout/2)
    |> ElGraph.add_edge(:greet, :shout)
    |> ElGraph.compile(entry: :greet)
  end

  describe "checkpointing during invoke (SPEC §3.5)" do
    test "saves a checkpoint for the initial state and every superstep", %{
      checkpointer: {mod, config} = checkpointer
    } do
      graph = sequential_graph()

      assert {:ok, %{result: "HELLO"}} =
               ElGraph.invoke(graph, %{}, checkpointer: checkpointer, thread_id: "t1")

      # 초기 상태(step 0) + superstep 2회 완료(step 1, 2) = 체크포인트 3개
      assert [%{step: 0}, %{step: 1}, %{step: 2}] = mod.list(config, "t1")

      assert {:ok, %Checkpoint{step: 2, next: [], state: %{result: "HELLO"}}} =
               mod.get(config, "t1", :latest)
    end

    test "a non-serializable value in state fails the invoke at checkpoint time", %{
      checkpointer: checkpointer
    } do
      graph =
        ElGraph.new()
        |> ElGraph.state(:x)
        |> ElGraph.add_node(:a, &TestNodes.write_pid/2)
        |> ElGraph.compile(entry: :a)

      assert {:error, {:not_serializable, _value}} =
               ElGraph.invoke(graph, %{}, checkpointer: checkpointer, thread_id: "t1")
    end
  end

  describe "resume (SPEC §3.5)" do
    test "resume of a completed thread returns the final state without re-running nodes", %{
      checkpointer: checkpointer
    } do
      graph = sequential_graph()

      {:ok, final} = ElGraph.invoke(graph, %{}, checkpointer: checkpointer, thread_id: "t1")

      assert {:ok, ^final} = ElGraph.resume(graph, checkpointer: checkpointer, thread_id: "t1")
    end

    test "resume without any checkpoint is an error", %{checkpointer: checkpointer} do
      graph = sequential_graph()

      assert {:error, :no_checkpoint} =
               ElGraph.resume(graph, checkpointer: checkpointer, thread_id: "ghost")
    end

    test "partial parallel failure persists pending writes and resume skips completed nodes", %{
      checkpointer: {mod, config} = checkpointer
    } do
      counter = :ets.new(:flaky_counter, [:public])

      graph =
        ElGraph.new()
        |> ElGraph.state(:messages, default: [], reducer: {Reducers, :append, []})
        |> ElGraph.add_node(:start, {TestNodes, :add_msg, ["s"]})
        |> ElGraph.add_node(:a, {TestNodes, :add_msg, ["a"]})
        |> ElGraph.add_node(:b, {TestNodes, :flaky_b, [counter]})
        |> ElGraph.add_edge(:start, :a)
        |> ElGraph.add_edge(:start, :b)
        |> ElGraph.compile(entry: :start)

      # 1차 실행: b가 실패하지만 a의 성공한 쓰기는 pending writes로 보존된다.
      assert {:error, {:node_crashed, :b, %RuntimeError{message: "flaky"}}} =
               ElGraph.invoke(graph, %{}, checkpointer: checkpointer, thread_id: "t2")

      assert [{:a, {%{messages: ["a"]}, nil}}] = mod.get_writes(config, "t2", 1)

      # 재개: a는 재실행하지 않고(쓰기 중복 없음) b만 다시 실행한다.
      assert {:ok, %{messages: ["s", "a", "b"]}} =
               ElGraph.resume(graph, checkpointer: checkpointer, thread_id: "t2")
    end
  end
end
