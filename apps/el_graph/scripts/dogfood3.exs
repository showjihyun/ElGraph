# 도그푸딩 세션 4: Sensor → Agent 체인 (실 OpenAI)
#   mix run scripts/dogfood3.exs
#
# DocsWatch 센서가 docs/ 변경을 감지 → "docs.changed" 시그널 →
# (어댑터로 변환) → SummarizeAgent가 변경 요약. Sensor + Agent 조합 관찰.

alias ElGraph.{Sensor, Signal}
alias ElGraph.Demo.{DocsWatch, SummarizeAgent}

key = ElGraph.Demo.fetch_api_key!()
{:ok, summarizer} = SummarizeAgent.start_link(llm: {ElGraph.LLM.OpenAI, api_key: key}, id: "sum", reply_to: self())

# 센서의 "docs.changed"를 요약 에이전트가 이해하는 "text.submitted"로 변환해 전달.
# (실제 시스템이라면 시그널 라우터/버스가 담당할 부분 — 여기선 인라인 어댑터로 관찰)
forward = fn %Signal{type: "docs.changed", data: %{from: from, to: to}} ->
  text = "ElGraph 문서가 변경되었습니다. 총 크기가 #{from} 바이트에서 #{to} 바이트로 바뀌었습니다."
  ElGraph.Agent.send_signal(summarizer, %Signal{type: "text.submitted", data: %{text: text}})
end

# start_size를 일부러 낮게 시드 → 첫 tick에서 "변경 감지"가 발생하도록.
{:ok, sensor} = DocsWatch.start_link(start_size: 0, on_signal: forward)

IO.puts("DocsWatch 센서 가동. 수동 tick으로 변경 감지를 트리거합니다...")
:ok = Sensor.tick(sensor)

receive do
  {:summary, %{answer: s, usage: u}} ->
    IO.puts("\n[Sensor→Agent 체인 성공]")
    IO.puts("요약: #{s}")
    IO.puts("tokens in/out: #{u.input_tokens}/#{u.output_tokens}")
after
  60_000 -> IO.puts("(timeout)")
end

# 두 번째 tick: 크기 변화 없음 → 조용해야 함 (이전 tick이 실제 크기로 갱신).
IO.puts("\n두 번째 tick (변경 없음 — 조용해야 함)...")
:ok = Sensor.tick(sensor)

receive do
  {:summary, _} -> IO.puts("⚠ 예상치 못한 시그널 (변경 없는데 발화)")
after
  3_000 -> IO.puts("✓ 조용함 — 변화 없을 때 발화하지 않음 확인")
end
