# 도그푸딩 세션 5: Store 장기기억 + 요약 압축 (실 OpenAI)
#   mix run scripts/dogfood5.exs
#
# 긴 대화를 만들고 Summarize 노드로 압축 → 축출분이 Store에 보관되는지 관찰.

alias ElGraph.{LLM, Reducers}
alias ElGraph.Nodes.Summarize
alias ElGraph.Store.ETS, as: Store

key = ElGraph.Demo.fetch_api_key!()
llm = {ElGraph.LLM.OpenAI, api_key: key}

{:ok, store_pid} = Store.start_link([])
store_config = Store.config(store_pid)
namespace = ["conversations", "demo"]

# 14턴 대화 시뮬레이션 (ElGraph 기능들에 대한 짧은 메시지).
topics = ~w(체크포인트 인터럽트 취소 스트리밍 재시도 타임아웃 서브그래프
            Action MCP ReAct 비용가드 Sensor Bus Store)

messages = Enum.map(topics, fn t -> LLM.user("#{t}에 대해 메모") end)

IO.puts("원본 대화: #{length(messages)}개 메시지")

# trigger 10 초과 → 압축. 최근 6개 유지, 나머지 8개 축출 → 요약 + Store 보관.
result =
  Summarize.run(%{messages: messages}, %{},
    llm: llm,
    trigger: {:messages, 10},
    keep: {:messages, 6},
    store: {Store, store_config, namespace}
  )

case result do
  %{messages: {:replace, compressed}} ->
    IO.puts("압축 후: #{length(compressed)}개 ([요약 1] + [최근 6])")
    [summary | recent] = compressed
    IO.puts("\n요약 메시지:\n  #{summary.content}")
    IO.puts("\n유지된 최근 메시지: #{Enum.map_join(recent, ", ", & &1.content)}")

  %{} ->
    IO.puts("압축 안 됨 (trigger 미달)")
end

# Store에 축출분이 보관됐는지 확인 (thread를 넘는 장기 기억).
IO.puts("\n[Store 장기기억 확인]")

case Store.list(store_config, namespace) do
  [{key, evicted}] ->
    IO.puts("축출분 보관됨: key=#{key}, #{length(evicted)}개 메시지")
    IO.puts("  내용: #{Enum.map_join(evicted, ", ", & &1.content)}")

  [] ->
    IO.puts("⚠ Store가 비어 있음")
end
