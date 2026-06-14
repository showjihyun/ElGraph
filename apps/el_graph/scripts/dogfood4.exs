# 도그푸딩 세션 4: Signal Bus로 발견 8 해소 (실 OpenAI)
#   mix run scripts/dogfood4.exs
#
# 세션 3에서 센서→에이전트를 인라인 클로저로 손수 이었다. 이제 버스로 푼다:
#   DocsWatch --("docs.changed")--> Bus --[변환 구독자]--> ("text.submitted") --> SummarizeAgent
# 에이전트는 자기 타입만 구독하고, 변환은 버스의 함수 구독이 담당한다.

alias ElGraph.Signal
alias ElGraph.Signal.Bus
alias ElGraph.Demo.{DocsWatch, SummarizeAgent}

key = ElGraph.Demo.fetch_api_key!()

{:ok, _} = Bus.start_link(name: DemoBus)

# 1. 요약 에이전트는 버스에서 "text.submitted"만 구독한다 (자기 타입).
{:ok, _} =
  SummarizeAgent.start_link(
    llm: {ElGraph.LLM.OpenAI, api_key: key},
    id: "sum",
    reply_to: self(),
    subscribe: {DemoBus, "text.submitted"}
  )

# 2. 변환 구독자: "docs.changed" → "text.submitted" 재발행 (버스가 라우팅, 변환은 함수 구독).
Bus.subscribe(DemoBus, "docs.changed", fn %Signal{data: %{from: f, to: t}} ->
  text = "ElGraph 문서가 #{f}바이트에서 #{t}바이트로 변경되었습니다."
  Bus.publish(DemoBus, %Signal{type: "text.submitted", data: %{text: text}})
end)

# 3. 센서는 버스에 발행만 한다 (대상을 모른다 — 디커플링).
{:ok, sensor} =
  DocsWatch.start_link(start_size: 0, on_signal: fn sig -> Bus.publish(DemoBus, sig) end)

IO.puts("센서 → 버스 → (변환) → 에이전트 체인 가동. tick으로 트리거...")
:ok = ElGraph.Sensor.tick(sensor)

receive do
  {:summary, %{answer: s, usage: u}} ->
    IO.puts("\n[버스 기반 체인 성공 — 센서/에이전트가 서로를 모른다]")
    IO.puts("요약: #{s}")
    IO.puts("tokens in/out: #{u.input_tokens}/#{u.output_tokens}")
after
  60_000 -> IO.puts("(timeout)")
end
