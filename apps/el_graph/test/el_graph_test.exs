defmodule ElGraphTest do
  use ExUnit.Case, async: true

  alias ElGraph.{CompileError, Reducers, TestNodes}

  defp messages_graph do
    ElGraph.new()
    |> ElGraph.state(:messages, default: [], reducer: {Reducers, :append, []})
  end

  describe "sequential execution" do
    test "threads state through nodes in edge order" do
      graph =
        ElGraph.new()
        |> ElGraph.state(:result)
        |> ElGraph.add_node(:greet, &TestNodes.greet/2)
        |> ElGraph.add_node(:shout, &TestNodes.shout/2)
        |> ElGraph.add_edge(:greet, :shout)
        |> ElGraph.compile(entry: :greet)

      assert {:ok, %{result: "HELLO"}} = ElGraph.invoke(graph, %{})
    end

    test "applies invoke input through reducers onto defaults" do
      graph =
        messages_graph()
        |> ElGraph.add_node(:one, {TestNodes, :add_msg, ["one"]})
        |> ElGraph.add_node(:two, {TestNodes, :add_msg, ["two"]})
        |> ElGraph.add_edge(:one, :two)
        |> ElGraph.compile(entry: :one)

      assert {:ok, %{messages: ["zero", "one", "two"]}} =
               ElGraph.invoke(graph, %{messages: ["zero"]})
    end
  end

  describe "conditional edges" do
    test "router loops until it returns :end" do
      graph =
        ElGraph.new()
        |> ElGraph.state(:count, default: 0, reducer: {Reducers, :add, []})
        |> ElGraph.add_node(:inc, &TestNodes.inc/2)
        |> ElGraph.add_conditional_edge(:inc, &TestNodes.route_until_three/1)
        |> ElGraph.compile(entry: :inc)

      assert {:ok, %{count: 3}} = ElGraph.invoke(graph, %{})
    end

    test "max_steps halts runaway loops" do
      graph =
        ElGraph.new()
        |> ElGraph.state(:count, default: 0, reducer: {Reducers, :add, []})
        |> ElGraph.add_node(:inc, &TestNodes.inc/2)
        |> ElGraph.add_edge(:inc, :inc)
        |> ElGraph.compile(entry: :inc)

      assert {:error, {:max_steps_exceeded, %{steps: 2}}} =
               ElGraph.invoke(graph, %{}, max_steps: 2)
    end

    test "router returning an unknown node errors" do
      graph =
        ElGraph.new()
        |> ElGraph.state(:count, default: 0, reducer: {Reducers, :add, []})
        |> ElGraph.add_node(:inc, &TestNodes.inc/2)
        |> ElGraph.add_conditional_edge(:inc, fn _state -> :nowhere end)
        |> ElGraph.compile(entry: :inc)

      assert {:error, {:invalid_router_target, :inc, :nowhere}} = ElGraph.invoke(graph, %{})
    end
  end

  describe "parallel fan-out" do
    test "merges parallel writes via reducer in deterministic node order" do
      graph =
        messages_graph()
        |> ElGraph.add_node(:start, {TestNodes, :add_msg, ["start"]})
        |> ElGraph.add_node(:a, {TestNodes, :add_msg, ["a"]})
        |> ElGraph.add_node(:b, {TestNodes, :add_msg, ["b"]})
        |> ElGraph.add_edge(:start, :a)
        |> ElGraph.add_edge(:start, :b)
        |> ElGraph.compile(entry: :start)

      assert {:ok, %{messages: ["start", "a", "b"]}} = ElGraph.invoke(graph, %{})
    end

    test "parallel writes to a non-reducer key are a conflict error" do
      graph =
        ElGraph.new()
        |> ElGraph.state(:x)
        |> ElGraph.add_node(:start, &TestNodes.noop/2)
        |> ElGraph.add_node(:x1, &TestNodes.write_x1/2)
        |> ElGraph.add_node(:x2, &TestNodes.write_x2/2)
        |> ElGraph.add_edge(:start, :x1)
        |> ElGraph.add_edge(:start, :x2)
        |> ElGraph.compile(entry: :start)

      assert {:error, {:write_conflict, :x, [:x1, :x2]}} = ElGraph.invoke(graph, %{})
    end
  end

  describe "state contract" do
    test "writing an undeclared key errors" do
      graph =
        ElGraph.new()
        |> ElGraph.state(:x)
        |> ElGraph.add_node(:a, &TestNodes.write_unknown/2)
        |> ElGraph.compile(entry: :a)

      assert {:error, {:unknown_state_key, :nope, :a}} = ElGraph.invoke(graph, %{})
    end

    test "input projection passes only the declared keys" do
      graph =
        ElGraph.new()
        |> ElGraph.state(:result, default: "r")
        |> ElGraph.state(:secret, default: "s")
        |> ElGraph.state(:seen)
        |> ElGraph.add_node(:a, &TestNodes.seen_keys/2, input: [:result])
        |> ElGraph.compile(entry: :a)

      assert {:ok, %{seen: [:result]}} = ElGraph.invoke(graph, %{})
    end
  end

  describe "node return contract" do
    test "non-map returns are rejected" do
      graph =
        ElGraph.new()
        |> ElGraph.state(:x)
        |> ElGraph.add_node(:a, &TestNodes.return_garbage/2)
        |> ElGraph.compile(entry: :a)

      assert {:error, {:invalid_node_return, :a, :oops}} = ElGraph.invoke(graph, %{})
    end

    test "a crashing node returns an error instead of taking down the caller" do
      graph =
        ElGraph.new()
        |> ElGraph.state(:x)
        |> ElGraph.add_node(:a, &TestNodes.boom/2)
        |> ElGraph.compile(entry: :a)

      assert {:error, {:node_crashed, :a, %RuntimeError{message: "boom"}}} =
               ElGraph.invoke(graph, %{})
    end
  end

  describe "ctx" do
    test "emit sends events to the event_sink" do
      graph =
        ElGraph.new()
        |> ElGraph.state(:x)
        |> ElGraph.add_node(:a, &TestNodes.emit_token/2)
        |> ElGraph.compile(entry: :a)

      assert {:ok, _state} = ElGraph.invoke(graph, %{}, event_sink: self(), thread_id: "t1")

      assert_receive {:el_graph_event,
                      %{thread_id: "t1", step: 0, node: :a, event: {:token, "hi"}}}
    end
  end

  describe "compile validation" do
    test "requires an entry node" do
      graph = ElGraph.new() |> ElGraph.add_node(:a, &TestNodes.noop/2)

      assert_raise CompileError, ~r/entry node is required/, fn -> ElGraph.compile(graph) end

      assert_raise CompileError, ~r/unknown node/, fn ->
        ElGraph.compile(graph, entry: :missing)
      end
    end

    test "rejects edges to unknown nodes" do
      graph =
        ElGraph.new()
        |> ElGraph.add_node(:a, &TestNodes.noop/2)
        |> ElGraph.add_edge(:a, :ghost)

      assert_raise CompileError, ~r/unknown node :ghost/, fn ->
        ElGraph.compile(graph, entry: :a)
      end
    end

    test "warns about statically unreachable nodes (may be :send/:command targets)" do
      graph =
        ElGraph.new()
        |> ElGraph.add_node(:a, &TestNodes.noop/2)
        |> ElGraph.add_node(:island, &TestNodes.noop/2)

      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert %ElGraph.Graph{} = ElGraph.compile(graph, entry: :a)
        end)

      assert warning =~ "unreachable"
      assert warning =~ ":island"
    end

    test "rejects local anonymous reducers" do
      graph =
        ElGraph.new()
        |> ElGraph.state(:x, reducer: fn a, b -> a + b end)
        |> ElGraph.add_node(:a, &TestNodes.noop/2)

      assert_raise CompileError, ~r/remote capture/, fn -> ElGraph.compile(graph, entry: :a) end
    end

    test "rejects :input referencing undeclared state keys" do
      graph =
        ElGraph.new()
        |> ElGraph.state(:x)
        |> ElGraph.add_node(:a, &TestNodes.noop/2, input: [:ghost])

      assert_raise CompileError, ~r/undeclared state key :ghost/, fn ->
        ElGraph.compile(graph, entry: :a)
      end
    end

    test "invoke on an uncompiled graph raises" do
      graph = ElGraph.new() |> ElGraph.add_node(:a, &TestNodes.noop/2)

      assert_raise ArgumentError, ~r/not compiled/, fn -> ElGraph.invoke(graph, %{}) end
    end
  end
end
