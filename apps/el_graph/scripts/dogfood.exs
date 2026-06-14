# 도그푸딩 세션: 데모 에이전트에 유형별 질문을 던지고 행동을 관찰한다 (실 OpenAI).
#   mix run scripts/dogfood.exs

{:ok, _pid} = ElGraph.Demo.start_link(reply_to: self())

questions = [
  "체크포인트 보존 정책 옵션은 뭐야?",
  "동적 인터럽트가 발생하면 노드는 어떻게 재실행되고, resume 값은 어떻게 매칭돼?",
  "LangGraph 대비 ElGraph의 장점을 3가지만 요약해줘.",
  "ElGraph로 비행기 예약하는 방법을 알려줘."
]

# 실행 중 introspection 샘플링 (두 번째 질문이 도는 동안)
spawn(fn ->
  Process.sleep(2_000)
  IO.inspect(ElGraph.Demo.runs(), label: "\n[introspection] 실행 중 run")
end)

Enum.each(questions, fn question ->
  IO.puts("\n========\n## Q: #{question}")
  started = System.monotonic_time(:millisecond)
  ElGraph.Demo.ask(question)

  receive do
    {:demo_answer, %{answer: answer, usage: usage}} ->
      elapsed = System.monotonic_time(:millisecond) - started
      IO.puts("[#{elapsed}ms, tokens in/out: #{usage.input_tokens}/#{usage.output_tokens}]")
      IO.puts(if is_binary(answer), do: answer, else: inspect(answer))
  after
    90_000 -> IO.puts("(90초 시간 초과)")
  end
end)

IO.inspect(ElGraph.Demo.runs(), label: "\n[introspection] 종료 후 run (비어 있어야 함)")
