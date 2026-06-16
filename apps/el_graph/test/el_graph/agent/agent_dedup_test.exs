defmodule ElGraph.Agent.DedupTest do
  use ExUnit.Case, async: true

  alias ElGraph.{Agent, Signal, TestAgent, TestNodes}

  defp graph do
    ElGraph.new()
    |> ElGraph.state(:result)
    |> ElGraph.add_node(:greet, &TestNodes.greet/2)
    |> ElGraph.compile(entry: :greet)
  end

  test "with dedup, a redelivered signal (same id) runs only once" do
    agent = start_supervised!({TestAgent, graph: graph(), id: "d1", owner: self(), dedup: 16})
    signal = Signal.ensure_id(%Signal{type: "task.assigned", data: %{}})

    Agent.send_signal(agent, signal)
    Agent.send_signal(agent, signal)

    assert_receive {:agent_result, "d1", {:ok, _}}
    refute_receive {:agent_result, "d1", _}, 100
  end

  test "without dedup, a redelivered signal runs each time" do
    agent = start_supervised!({TestAgent, graph: graph(), id: "d2", owner: self()})
    signal = Signal.ensure_id(%Signal{type: "task.assigned", data: %{}})

    Agent.send_signal(agent, signal)
    Agent.send_signal(agent, signal)

    assert_receive {:agent_result, "d2", {:ok, _}}
    assert_receive {:agent_result, "d2", {:ok, _}}
  end
end
