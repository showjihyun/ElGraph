defmodule ElGraph.SendCommandTest do
  use ExUnit.Case, async: true

  alias ElGraph.{CompileError, Reducers, TestNodes}

  # 여러 소스 노드가 한 superstep에서 각각 fan-out하는 경로 검증용 헬퍼.
  def two_sends(_state, _ctx, t1, t2), do: [{:send, t1, %{}}, {:send, t2, %{}}]
  def fan_to(_state, _ctx, target, tags), do: Enum.map(tags, &{:send, target, %{tag: &1}})
  def collect_tag(%{tag: tag}, _ctx), do: %{log: [tag]}

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

    test "merges sends from multiple source nodes in one superstep, preserving order" do
      {graph, _warning} =
        ExUnit.CaptureIO.with_io(:stderr, fn ->
          ElGraph.new()
          |> ElGraph.state(:log, default: [], reducer: {Reducers, :append, []})
          |> ElGraph.add_node(:plan, {__MODULE__, :two_sends, [:a, :b]})
          |> ElGraph.add_node(:a, {__MODULE__, :fan_to, [:sink, ["a1", "a2"]]})
          |> ElGraph.add_node(:b, {__MODULE__, :fan_to, [:sink, ["b1", "b2"]]})
          |> ElGraph.add_node(:sink, &__MODULE__.collect_tag/2)
          |> ElGraph.compile(entry: :plan)
        end)

      # :a와 :b가 한 superstep에서 각각 :sink로 fan-out → next_entries가 여러 결과의
      # sends를 누적한다. 결과 순서(a 먼저)와 각 노드 내 send 순서가 보존돼야 한다.
      assert {:ok, %{log: ["a1", "a2", "b1", "b2"]}} = ElGraph.invoke(graph, %{})
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
