defmodule ElGraph.Nodes.MemoryTest do
  use ExUnit.Case, async: true

  alias ElGraph.Memory
  alias ElGraph.Nodes.Memory, as: MemoryNode
  alias ElGraph.Store.ETS, as: Store

  setup do
    pid = start_supervised!({Store, []})
    %{mem: Memory.new({Store, Store.config(pid)})}
  end

  @ns ["users", "u1"]

  test "record_node → recall_node round-trips an episode through the graph", %{mem: mem} do
    graph =
      ElGraph.new()
      |> ElGraph.state(:messages, default: [])
      |> ElGraph.state(:recalled, default: [])
      |> ElGraph.add_node(:record, MemoryNode.record_node(mem, @ns, []))
      |> ElGraph.add_node(:recall, MemoryNode.recall_node(mem, @ns, []))
      |> ElGraph.add_edge(:record, :recall)
      |> ElGraph.add_conditional_edge(:recall, fn _ -> :end end)
      |> ElGraph.compile(entry: :record)

    input = %{messages: [%{role: :user, content: "asked about pricing"}]}

    assert {:ok, %{recalled: recalled}} = ElGraph.invoke(graph, input)
    assert "asked about pricing" in recalled
  end

  test "recall_node honours a custom state key and limit", %{mem: mem} do
    :ok = Memory.record_episode(mem, @ns, "old", at: 1)
    :ok = Memory.record_episode(mem, @ns, "new", at: 2)

    {mod, fun, args} = MemoryNode.recall_node(mem, @ns, into: :history, limit: 1)
    assert %{history: ["new"]} = apply(mod, fun, [%{}, %ElGraph.Ctx{} | args])
  end
end
