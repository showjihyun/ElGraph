defmodule ElGraph.AgentTest do
  use ExUnit.Case, async: true

  alias ElGraph.{Agent, Reducers, Signal, TestAgent, TestNodes}
  alias ElGraph.Checkpointer.ETS

  defp sequential_graph do
    ElGraph.new()
    |> ElGraph.state(:result)
    |> ElGraph.add_node(:greet, &TestNodes.greet/2)
    |> ElGraph.add_node(:shout, &TestNodes.shout/2)
    |> ElGraph.add_edge(:greet, :shout)
    |> ElGraph.compile(entry: :greet)
  end

  defp slow_graph(sleep_ms) do
    ElGraph.new()
    |> ElGraph.state(:result)
    |> ElGraph.add_node(:work, {TestNodes, :slow, [sleep_ms]})
    |> ElGraph.compile(entry: :work)
  end

  defp signal(data \\ %{}), do: %Signal{type: "task.assigned", data: data}

  describe "에이전트 = 그래프 + 메일박스 (SPEC §5)" do
    test "a signal triggers a graph run and handle_result receives the outcome" do
      agent = start_supervised!({TestAgent, graph: sequential_graph(), id: "a1", owner: self()})

      Agent.send_signal(agent, signal())

      assert_receive {:agent_result, "a1", {:ok, %{result: "HELLO"}}}
    end

    test "handle_signal can ignore signals" do
      agent = start_supervised!({TestAgent, graph: sequential_graph(), id: "a2", owner: self()})

      Agent.send_signal(agent, %Signal{type: "ignore.this"})

      refute_receive {:agent_result, "a2", _result}, 100
    end

    test "the agent stays responsive while a run is in flight" do
      agent = start_supervised!({TestAgent, graph: slow_graph(300), id: "a3", owner: self()})

      Agent.send_signal(agent, signal())

      # 실행 중에도 GenServer 콜백은 블록되지 않는다.
      assert %{running: true, queued: 0} = Agent.status(agent)
      assert_receive {:agent_result, "a3", {:ok, _state}}, 2_000
      assert %{running: false} = Agent.status(agent)
    end

    test "signals during a run are queued and processed serially" do
      agent = start_supervised!({TestAgent, graph: slow_graph(50), id: "a4", owner: self()})

      Agent.send_signal(agent, signal())
      Agent.send_signal(agent, signal())

      assert %{queued: 1} = Agent.status(agent)
      assert_receive {:agent_result, "a4", {:ok, _first}}, 2_000
      assert_receive {:agent_result, "a4", {:ok, _second}}, 2_000
    end

    test "agents are addressable via a Registry without dynamic atoms" do
      registry = start_supervised!({Registry, keys: :unique, name: ElGraph.AgentTest.Registry})
      _ = registry

      start_supervised!(
        {TestAgent,
         graph: sequential_graph(),
         id: "named-1",
         owner: self(),
         registry: ElGraph.AgentTest.Registry},
        id: :agent_named
      )

      Agent.send_signal(Agent.via(ElGraph.AgentTest.Registry, "named-1"), signal())

      assert_receive {:agent_result, "named-1", {:ok, %{result: "HELLO"}}}
    end
  end

  describe "crash-only 복구 (SPEC §5)" do
    test "an incomplete thread resumes automatically on agent start" do
      checkpointer_pid = start_supervised!(ETS)
      checkpointer = {ETS, ETS.config(checkpointer_pid)}
      counter = :ets.new(:agent_flaky, [:public])

      graph =
        ElGraph.new()
        |> ElGraph.state(:messages, default: [], reducer: {Reducers, :append, []})
        |> ElGraph.add_node(:start, {TestNodes, :add_msg, ["s"]})
        |> ElGraph.add_node(:a, {TestNodes, :add_msg, ["a"]})
        |> ElGraph.add_node(:b, {TestNodes, :flaky_b, [counter]})
        |> ElGraph.add_edge(:start, :a)
        |> ElGraph.add_edge(:start, :b)
        |> ElGraph.compile(entry: :start)

      # 이전 생애에서 실행이 중간에 죽었다 — 미완료 체크포인트가 남아 있다.
      {:error, {:node_crashed, :b, _}} =
        ElGraph.invoke(graph, %{}, checkpointer: checkpointer, thread_id: "agent-thread")

      # 에이전트가 (재)시작되면 미완료 thread를 스스로 재개한다.
      start_supervised!(
        {TestAgent,
         graph: graph,
         id: "rec",
         owner: self(),
         checkpointer: checkpointer,
         thread_id: "agent-thread"}
      )

      assert_receive {:agent_result, "rec", {:ok, %{messages: ["s", "a", "b"]}}}, 2_000
    end
  end
end
