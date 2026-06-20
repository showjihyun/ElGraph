defmodule ElGraph.InterruptTest do
  use ExUnit.Case, async: true

  alias ElGraph.{Reducers, TestNodes}
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

  defp ask_graph(node_fun) do
    ElGraph.new()
    |> ElGraph.state(:result)
    |> ElGraph.add_node(:ask, node_fun)
    |> ElGraph.compile(entry: :ask)
  end

  describe "static interrupt: interrupt_before (SPEC §3.6)" do
    test "pauses before the node and resume continues", %{checkpointer: checkpointer} do
      graph = sequential_graph()

      assert {:interrupted, %{step: 1, before: [:shout], state: %{result: "hello"}}} =
               ElGraph.invoke(graph, %{},
                 checkpointer: checkpointer,
                 thread_id: "t1",
                 interrupt_before: [:shout]
               )

      assert {:ok, %{result: "HELLO"}} =
               ElGraph.resume(graph, checkpointer: checkpointer, thread_id: "t1")
    end

    test "pauses before the entry node, before any execution", %{checkpointer: checkpointer} do
      graph = sequential_graph()

      assert {:interrupted, %{step: 0, before: [:greet], state: %{result: nil}}} =
               ElGraph.invoke(graph, %{},
                 checkpointer: checkpointer,
                 thread_id: "t1",
                 interrupt_before: [:greet]
               )

      assert {:ok, %{result: "HELLO"}} =
               ElGraph.resume(graph, checkpointer: checkpointer, thread_id: "t1")
    end

    test "requires a checkpointer" do
      graph = sequential_graph()

      assert_raise ArgumentError, ~r/checkpointer/, fn ->
        ElGraph.invoke(graph, %{}, interrupt_before: [:shout])
      end
    end
  end

  describe "dynamic interrupt: Ctx.interrupt (SPEC §3.6)" do
    test "pauses the node and resume injects the value", %{checkpointer: checkpointer} do
      graph = ask_graph(&TestNodes.ask/2)

      assert {:interrupted, %{node: :ask, payload: %{question: "name?"}, step: 0}} =
               ElGraph.invoke(graph, %{}, checkpointer: checkpointer, thread_id: "t1")

      assert {:ok, %{result: "Alice"}} =
               ElGraph.resume(graph,
                 checkpointer: checkpointer,
                 thread_id: "t1",
                 resume: "Alice"
               )
    end

    test "side effects before the interrupt re-run on resume (documented semantics)", %{
      checkpointer: checkpointer
    } do
      graph = ask_graph(&TestNodes.emit_then_ask/2)

      assert {:interrupted, _info} =
               ElGraph.invoke(graph, %{},
                 checkpointer: checkpointer,
                 thread_id: "t1",
                 event_sink: self()
               )

      assert_receive {:el_graph_event, %{event: :before_interrupt}}

      assert {:ok, %{result: "x"}} =
               ElGraph.resume(graph,
                 checkpointer: checkpointer,
                 thread_id: "t1",
                 resume: "x",
                 event_sink: self()
               )

      # 노드가 처음부터 재실행되므로 interrupt 이전의 emit은 한 번 더 발생한다.
      assert_receive {:el_graph_event, %{event: :before_interrupt}}
    end

    test "multiple interrupts in one node are matched by call order", %{
      checkpointer: checkpointer
    } do
      graph = ask_graph(&TestNodes.double_ask/2)

      assert {:interrupted, %{node: :ask, payload: :q1}} =
               ElGraph.invoke(graph, %{}, checkpointer: checkpointer, thread_id: "t1")

      assert {:interrupted, %{node: :ask, payload: :q2}} =
               ElGraph.resume(graph, checkpointer: checkpointer, thread_id: "t1", resume: "A")

      assert {:ok, %{result: {"A", "B"}}} =
               ElGraph.resume(graph, checkpointer: checkpointer, thread_id: "t1", resume: "B")
    end

    test "parallel sibling writes are preserved and not re-run", %{
      checkpointer: {mod, config} = checkpointer
    } do
      graph =
        ElGraph.new()
        |> ElGraph.state(:messages, default: [], reducer: {Reducers, :append, []})
        |> ElGraph.add_node(:start, {TestNodes, :add_msg, ["s"]})
        |> ElGraph.add_node(:a, {TestNodes, :add_msg, ["a"]})
        |> ElGraph.add_node(:ask, &TestNodes.ask_msg/2)
        |> ElGraph.add_edge(:start, :a)
        |> ElGraph.add_edge(:start, :ask)
        |> ElGraph.compile(entry: :start)

      assert {:interrupted, %{node: :ask, payload: :ask, step: 1}} =
               ElGraph.invoke(graph, %{}, checkpointer: checkpointer, thread_id: "t2")

      # 병렬 형제 a는 완료까지 실행되고 그 쓰기가 보존된다.
      assert [{:a, {%{messages: ["a"]}, nil}}] = mod.get_writes(config, "t2", 1)

      # 재개: a는 재실행하지 않고(중복 없음) ask만 주입된 값으로 재실행한다.
      assert {:ok, %{messages: ["s", "a", "X"]}} =
               ElGraph.resume(graph, checkpointer: checkpointer, thread_id: "t2", resume: "X")
    end

    test "3+ parallel sibling writes are all preserved when one sibling interrupts", %{
      checkpointer: {mod, config} = checkpointer
    } do
      graph =
        ElGraph.new()
        |> ElGraph.state(:messages, default: [], reducer: {Reducers, :append, []})
        |> ElGraph.add_node(:start, {TestNodes, :add_msg, ["s"]})
        |> ElGraph.add_node(:a, {TestNodes, :add_msg, ["a"]})
        |> ElGraph.add_node(:b, {TestNodes, :add_msg, ["b"]})
        |> ElGraph.add_node(:ask, &TestNodes.ask_msg/2)
        |> ElGraph.add_edge(:start, :a)
        |> ElGraph.add_edge(:start, :b)
        |> ElGraph.add_edge(:start, :ask)
        |> ElGraph.compile(entry: :start)

      assert {:interrupted, %{node: :ask, payload: :ask, step: 1}} =
               ElGraph.invoke(graph, %{}, checkpointer: checkpointer, thread_id: "t3")

      # 완료된 두 형제(a, b)의 쓰기가 모두 보존된다 — 2-형제를 넘는 부분 실패 보존.
      assert [{:a, {%{messages: ["a"]}, nil}}, {:b, {%{messages: ["b"]}, nil}}] =
               mod.get_writes(config, "t3", 1) |> Enum.sort()

      # 재개: a·b는 재실행하지 않고(중복 없음) ask만 주입값으로 실행한다.
      assert {:ok, %{messages: msgs}} =
               ElGraph.resume(graph, checkpointer: checkpointer, thread_id: "t3", resume: "X")

      assert ["X", "a", "b", "s"] = Enum.sort(msgs)
    end

    test "dynamic interrupt without a checkpointer is an explicit error" do
      graph = ask_graph(&TestNodes.ask/2)

      assert {:error, {:interrupt_requires_checkpointer, :ask, %{question: "name?"}}} =
               ElGraph.invoke(graph, %{})
    end
  end
end
