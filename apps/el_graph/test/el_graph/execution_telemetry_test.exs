defmodule ElGraph.ExecutionTelemetryTest do
  use ExUnit.Case, async: true

  alias ElGraph.TestNodes
  alias ElGraph.Checkpointer.ETS

  def put1(_state, _ctx), do: %{result: 1}
  def put2(_state, _ctx), do: %{result: 2}

  describe "retry telemetry (SPEC §4)" do
    test "emits a node.retry event per retry attempt with reason and attempt" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:el_graph, :node, :retry]])

      table = :ets.new(:retry_tel, [:public])

      graph =
        ElGraph.new()
        |> ElGraph.state(:result)
        |> ElGraph.add_node(:work, {TestNodes, :fail_times, [table, 2]},
          retry: [max: 2, backoff: :none]
        )
        |> ElGraph.compile(entry: :work)

      assert {:ok, _} = ElGraph.invoke(graph, %{}, thread_id: "t1")

      # 2번 실패 → 2번 재시도 이벤트 (attempt 1, 2).
      assert_receive {[:el_graph, :node, :retry], ^ref, %{attempt: 1},
                      %{node: :work, thread_id: "t1", reason: {:node_crashed, :work, _}}}

      assert_receive {[:el_graph, :node, :retry], ^ref, %{attempt: 2}, %{node: :work}}

      # thread_id로 격리 — telemetry 핸들러는 전역이라 부재 검증은 자기 thread만 본다.
      refute_receive {[:el_graph, :node, :retry], ^ref, %{attempt: 3}, %{thread_id: "t1"}}, 50
    end
  end

  describe "interrupt telemetry (SPEC §3.6)" do
    test "emits a node.interrupt event when a node interrupts dynamically" do
      cp_pid = start_supervised!(ETS)
      cp = {ETS, ETS.config(cp_pid)}
      ref = :telemetry_test.attach_event_handlers(self(), [[:el_graph, :node, :interrupt]])

      graph =
        ElGraph.new()
        |> ElGraph.state(:result)
        |> ElGraph.add_node(:ask, &TestNodes.ask/2)
        |> ElGraph.compile(entry: :ask)

      assert {:interrupted, _} =
               ElGraph.invoke(graph, %{}, checkpointer: cp, thread_id: "t2")

      assert_receive {[:el_graph, :node, :interrupt], ^ref, %{},
                      %{
                        node: :ask,
                        thread_id: "t2",
                        payload: %{question: "name?"},
                        kind: :dynamic
                      }}
    end

    test "emits a static node.interrupt event for interrupt_before nodes" do
      cp_pid = start_supervised!(ETS)
      cp = {ETS, ETS.config(cp_pid)}
      ref = :telemetry_test.attach_event_handlers(self(), [[:el_graph, :node, :interrupt]])

      graph =
        ElGraph.new()
        |> ElGraph.state(:result)
        |> ElGraph.add_node(:a, {__MODULE__, :put1, []})
        |> ElGraph.add_node(:b, {__MODULE__, :put2, []})
        |> ElGraph.add_edge(:a, :b)
        |> ElGraph.compile(entry: :a)

      assert {:interrupted, %{before: [:b]}} =
               ElGraph.invoke(graph, %{},
                 checkpointer: cp,
                 thread_id: "t3",
                 interrupt_before: [:b]
               )

      assert_receive {[:el_graph, :node, :interrupt], ^ref, %{},
                      %{node: :b, thread_id: "t3", kind: :static}}
    end
  end
end
