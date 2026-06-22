defmodule ElGraph.Nodes.MemoryTest do
  use ExUnit.Case, async: true

  alias ElGraph.Memory
  alias ElGraph.Nodes.Memory, as: MemoryNode
  alias ElGraph.Store.ETS, as: Store

  # 결정적 테스트 embedder: a-z 글자 빈도 벡터 (어휘가 비슷할수록 코사인 유사도↑).
  defmodule CharEmbedder do
    @behaviour ElGraph.Memory.Embedder

    @impl true
    def embed(text) do
      freq =
        text
        |> String.downcase()
        |> String.to_charlist()
        |> Enum.filter(&(&1 in ?a..?z))
        |> Enum.frequencies()

      for c <- ?a..?z, do: Map.get(freq, c, 0) / 1.0
    end
  end

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

  test "recall_node with :embedder does semantic recall over the :query_key state field", %{
    mem: mem
  } do
    :ok = Memory.record_episode(mem, @ns, "billing and pricing question", at: 1)

    # 최신(at:2)이지만 어휘가 다르다 — 시맨틱 회수면 쿼리에 가까운 at:1이 위로 와야 한다.
    :ok = Memory.record_episode(mem, @ns, "weather forecast today", at: 2)

    {mod, fun, args} =
      MemoryNode.recall_node(mem, @ns, embedder: CharEmbedder, query_key: :q, into: :hits)

    assert %{hits: [top | _]} = apply(mod, fun, [%{q: "pricing"}, %ElGraph.Ctx{} | args])
    assert top == "billing and pricing question"
  end

  test "record_node reads the value from a custom :from state key", %{mem: mem} do
    {mod, fun, args} = MemoryNode.record_node(mem, @ns, from: :note)

    assert %{} == apply(mod, fun, [%{note: "remember this"}, %ElGraph.Ctx{} | args])
    assert "remember this" in Memory.recall_episodes(mem, @ns)
  end

  test "record_node records nothing when no event can be extracted", %{mem: mem} do
    {mod, fun, args} = MemoryNode.record_node(mem, @ns, [])
    ctx = %ElGraph.Ctx{}

    # 메시지 키 자체가 없음 → last_message_content(_state) fallback
    assert %{} == apply(mod, fun, [%{}, ctx | args])
    # 마지막 메시지에 :content 없음 → list 절의 _ -> nil
    assert %{} == apply(mod, fun, [%{messages: [%{role: :user}]}, ctx | args])

    assert [] == Memory.recall_episodes(mem, @ns)
  end
end
