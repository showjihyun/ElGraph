defmodule ElGraph.CheckpointTelemetryTest do
  use ExUnit.Case, async: true

  alias ElGraph.TestNodes
  alias ElGraph.Checkpointer.ETS

  test "do_put emits a checkpoint.put event with thread_id and step" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:el_graph, :checkpoint, :put]])

    cp_pid = start_supervised!(ETS)
    cp = {ETS, ETS.config(cp_pid)}

    graph =
      ElGraph.new()
      |> ElGraph.state(:result)
      |> ElGraph.add_node(:greet, &TestNodes.greet/2)
      |> ElGraph.compile(entry: :greet)

    assert {:ok, _state} = ElGraph.invoke(graph, %{}, checkpointer: cp, thread_id: "cp-t1")

    assert_receive {[:el_graph, :checkpoint, :put], ^ref, %{}, %{thread_id: "cp-t1", step: _step}}
  end
end
