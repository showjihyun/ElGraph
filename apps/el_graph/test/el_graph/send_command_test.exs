defmodule ElGraph.SendCommandTest do
  use ExUnit.Case, async: true

  alias ElGraph.{CompileError, Reducers, TestNodes}

  describe ":command (SPEC §3.2)" do
    test "applies the update and jumps to the target, ignoring static edges" do
      # :c는 정적 경로가 없어 도달 불가 경고가 나지만 의도된 것(command 대상)이므로 출력만 흡수.
      {graph, _warning} =
        ExUnit.CaptureIO.with_io(:stderr, fn ->
          ElGraph.new()
          |> ElGraph.state(:result)
          |> ElGraph.add_node(:a, {TestNodes, :command_goto, [:c, %{result: "from-a"}]})
          |> ElGraph.add_node(:b, &TestNodes.shout/2)
          |> ElGraph.add_node(:c, &TestNodes.shout/2)
          |> ElGraph.add_edge(:a, :b)
          |> ElGraph.compile(entry: :a)
        end)

      # b가 함께 실행됐다면 :result에 병렬 쓰기 충돌이 났을 것 — c만 실행됨을 보장.
      assert {:ok, %{result: "FROM-A"}} = ElGraph.invoke(graph, %{})
    end

    test "{:command, :end, update} applies the update and terminates" do
      graph =
        ElGraph.new()
        |> ElGraph.state(:result)
        |> ElGraph.add_node(:a, {TestNodes, :command_goto, [:end, %{result: "done"}]})
        |> ElGraph.add_node(:b, &TestNodes.shout/2)
        |> ElGraph.add_edge(:a, :b)
        |> ElGraph.compile(entry: :a)

      assert {:ok, %{result: "done"}} = ElGraph.invoke(graph, %{})
    end

    test "goto to an unknown node is an error" do
      graph =
        ElGraph.new()
        |> ElGraph.state(:result)
        |> ElGraph.add_node(:a, {TestNodes, :command_goto, [:nowhere, %{}]})
        |> ElGraph.compile(entry: :a)

      assert {:error, {:invalid_goto, :a, :nowhere}} = ElGraph.invoke(graph, %{})
    end
  end

  describe ":send dynamic fan-out (SPEC §3.2)" do
    test "spawns one execution per send, each with its own input (map-reduce)" do
      {graph, _warning} =
        ExUnit.CaptureIO.with_io(:stderr, fn ->
          ElGraph.new()
          |> ElGraph.state(:results, default: [], reducer: {Reducers, :append, []})
          |> ElGraph.add_node(:plan, {TestNodes, :plan_sends, [[1, 2, 3], :worker]})
          |> ElGraph.add_node(:worker, &TestNodes.times_ten/2)
          |> ElGraph.compile(entry: :plan)
        end)

      assert {:ok, %{results: [10, 20, 30]}} = ElGraph.invoke(graph, %{})
    end

    test "a send to an unknown node is an error" do
      graph =
        ElGraph.new()
        |> ElGraph.state(:results)
        |> ElGraph.add_node(:plan, {TestNodes, :plan_sends, [[1], :nowhere]})
        |> ElGraph.compile(entry: :plan)

      assert {:error, {:invalid_send_target, :plan, :nowhere}} = ElGraph.invoke(graph, %{})
    end
  end

  describe "subgraph (SPEC §3.10)" do
    defp subgraph do
      ElGraph.new()
      |> ElGraph.state(:result)
      |> ElGraph.add_node(:greet, &TestNodes.greet/2)
      |> ElGraph.add_node(:shout, &TestNodes.shout/2)
      |> ElGraph.add_edge(:greet, :shout)
      |> ElGraph.compile(entry: :greet)
    end

    test "a compiled graph runs as a node over shared state keys" do
      graph =
        ElGraph.new()
        |> ElGraph.state(:result)
        |> ElGraph.add_node(:sub, subgraph())
        |> ElGraph.compile(entry: :sub)

      assert {:ok, %{result: "HELLO"}} = ElGraph.invoke(graph, %{})
    end

    test "subgraph errors crash the node" do
      failing_sub =
        ElGraph.new()
        |> ElGraph.state(:result)
        |> ElGraph.add_node(:boom, &TestNodes.boom/2)
        |> ElGraph.compile(entry: :boom)

      graph =
        ElGraph.new()
        |> ElGraph.state(:result)
        |> ElGraph.add_node(:sub, failing_sub)
        |> ElGraph.compile(entry: :sub)

      assert {:error, {:node_crashed, :sub, %ElGraph.SubgraphError{}}} =
               ElGraph.invoke(graph, %{})
    end

    test "compile rejects an uncompiled subgraph" do
      uncompiled = ElGraph.new() |> ElGraph.add_node(:x, &TestNodes.noop/2)

      assert_raise CompileError, ~r/compile/, fn ->
        ElGraph.new()
        |> ElGraph.state(:result)
        |> ElGraph.add_node(:sub, uncompiled)
        |> ElGraph.compile(entry: :sub)
      end
    end
  end
end
