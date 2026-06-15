defmodule ElGraph.Agent.AgentTelemetryTest do
  use ExUnit.Case, async: true

  alias ElGraph.{Agent, Signal, TestAgent, TestNodes}

  defp sequential_graph do
    ElGraph.new()
    |> ElGraph.state(:result)
    |> ElGraph.add_node(:greet, &TestNodes.greet/2)
    |> ElGraph.compile(entry: :greet)
  end

  test "a triggered run emits agent.start and agent.stop with the agent id and status" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:el_graph, :agent, :start],
        [:el_graph, :agent, :stop]
      ])

    agent = start_supervised!({TestAgent, graph: sequential_graph(), id: "tel-1", owner: self()})

    Agent.send_signal(agent, %Signal{type: "task.assigned", data: %{}})

    assert_receive {[:el_graph, :agent, :start], ^ref, _measurements, %{agent_id: "tel-1"}}

    assert_receive {[:el_graph, :agent, :stop], ^ref, _measurements,
                    %{agent_id: "tel-1", status: :ok}}
  end
end
