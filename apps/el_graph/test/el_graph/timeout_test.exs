defmodule ElGraph.TimeoutTest do
  use ExUnit.Case, async: true

  alias ElGraph.{CompileError, Reducers, TestNodes}
  alias ElGraph.Checkpointer.ETS

  defp slow_graph(timeout, sleep_ms) do
    ElGraph.new()
    |> ElGraph.state(:result)
    |> ElGraph.add_node(:work, {TestNodes, :slow, [sleep_ms]}, timeout: timeout)
    |> ElGraph.compile(entry: :work)
  end

  describe "node timeout (SPEC §3.4)" do
    test "a node exceeding its timeout returns a node_timeout error" do
      assert {:error, {:node_timeout, :work, 20}} = ElGraph.invoke(slow_graph(20, 500), %{})
    end

    test "a node finishing within its timeout succeeds" do
      assert {:ok, %{result: :done}} = ElGraph.invoke(slow_graph(1_000, 5), %{})
    end

    test "the timeout option is validated at compile time" do
      assert_raise CompileError, ~r/:timeout/, fn ->
        ElGraph.new()
        |> ElGraph.state(:result)
        |> ElGraph.add_node(:work, &TestNodes.noop/2, timeout: -5)
        |> ElGraph.compile(entry: :work)
      end
    end

    test "Ctx.interrupt still works inside a node with a timeout" do
      checkpointer_pid = start_supervised!(ETS)
      checkpointer = {ETS, ETS.config(checkpointer_pid)}

      graph =
        ElGraph.new()
        |> ElGraph.state(:result)
        |> ElGraph.add_node(:ask, &TestNodes.ask/2, timeout: 1_000)
        |> ElGraph.compile(entry: :ask)

      assert {:interrupted, %{node: :ask, payload: %{question: "name?"}}} =
               ElGraph.invoke(graph, %{}, checkpointer: checkpointer, thread_id: "t1")

      assert {:ok, %{result: "Alice"}} =
               ElGraph.resume(graph,
                 checkpointer: checkpointer,
                 thread_id: "t1",
                 resume: "Alice"
               )
    end

    test "sibling writes are preserved on timeout and resume retries only the slow node" do
      checkpointer_pid = start_supervised!(ETS)
      {mod, config} = checkpointer = {ETS, ETS.config(checkpointer_pid)}
      counter = :ets.new(:slow_counter, [:public])

      graph =
        ElGraph.new()
        |> ElGraph.state(:messages, default: [], reducer: {Reducers, :append, []})
        |> ElGraph.add_node(:start, {TestNodes, :add_msg, ["s"]})
        |> ElGraph.add_node(:a, {TestNodes, :add_msg, ["a"]})
        |> ElGraph.add_node(:b, {TestNodes, :slow_once, [counter, 1_000]}, timeout: 50)
        |> ElGraph.add_edge(:start, :a)
        |> ElGraph.add_edge(:start, :b)
        |> ElGraph.compile(entry: :start)

      assert {:error, {:node_timeout, :b, 50}} =
               ElGraph.invoke(graph, %{}, checkpointer: checkpointer, thread_id: "t1")

      # 병렬 형제 a의 완료된 쓰기는 보존된다.
      assert [{:a, {%{messages: ["a"]}, nil}}] = mod.get_writes(config, "t1", 1)

      # 재개: a는 재실행하지 않고 b만 다시 실행한다 (두 번째 호출은 즉시 성공).
      assert {:ok, %{messages: ["s", "a", "b"]}} =
               ElGraph.resume(graph, checkpointer: checkpointer, thread_id: "t1")
    end
  end
end
