# 도그푸딩 세션 2: 대화 맥락 / 동시 부하(RateLimiter) / 두 번째 에이전트 유형
#   mix run scripts/dogfood2.exs

alias ElGraph.{Agent, RateLimiter, Signal}
alias ElGraph.Demo.SummarizeAgent

key = ElGraph.Demo.fetch_api_key!()
llm = {ElGraph.LLM.OpenAI, api_key: key}

## 관찰 1: 대화 맥락 유지 — 데모 트리에서 연속 질문
IO.puts("\n===== 관찰 1: 대화 맥락 유지 =====")
{:ok, _} = ElGraph.Demo.start_link(reply_to: self())

ask = fn q ->
  IO.puts("\nQ: #{q}")
  ElGraph.Demo.ask(q)

  receive do
    {:demo_answer, %{answer: a}} -> IO.puts("A: #{a}")
  after
    60_000 -> IO.puts("(timeout)")
  end
end

ask.("ElGraph의 체크포인트는 무엇을 저장해?")
# 맥락 의존 질문 — "그것"이 직전 답을 가리킨다. 맥락 유지되면 답하고, 안 되면 되묻거나 헛답.
ask.("방금 설명한 그 보존 정책의 옵션 이름만 나열해줘.")

## 관찰 2: RateLimiter 동시 부하 실증
IO.puts("\n===== 관찰 2: RateLimiter (limit 2, 동시 5) =====")
{:ok, limiter} = RateLimiter.start_link(limit: 2)
parent = self()

tasks =
  for i <- 1..5 do
    Task.async(fn ->
      RateLimiter.with_limit(limiter, fn ->
        send(parent, {:acquired, i, System.monotonic_time(:millisecond)})
        Process.sleep(300)
        i
      end)
    end)
  end

# 획득 타임스탬프를 모아 동시성이 2로 제한됐는지 본다.
acquires =
  for _ <- 1..5 do
    receive do
      {:acquired, i, t} -> {i, t}
    end
  end

Task.await_many(tasks)
t0 = acquires |> Enum.map(&elem(&1, 1)) |> Enum.min()
waves = acquires |> Enum.map(fn {i, t} -> {i, t - t0} end) |> Enum.sort_by(&elem(&1, 1))
IO.puts("획득 시점(ms, 시작 기준): #{inspect(waves)}")
IO.puts("→ ~0ms 2개, ~300ms 2개, ~600ms 1개면 limit 2가 동작한 것")

## 관찰 3: 두 번째 에이전트 유형 (요약, 툴 없음)
IO.puts("\n===== 관찰 3: SummarizeAgent (툴 없는 변환) =====")
{:ok, sum} = SummarizeAgent.start_link(llm: llm, id: "sum", reply_to: self())

text =
  "ElGraph는 BEAM 위에서 도는 graph-first 에이전트 프레임워크로, 체크포인트 기반 내구 실행, " <>
    "human-in-the-loop 인터럽트, 병렬 fan-out, 취소를 코어에서 제공하며 LangGraph의 운영 약점을 보완한다."

Agent.send_signal(sum, %Signal{type: "text.submitted", data: %{text: text}})

receive do
  {:summary, %{answer: s}} -> IO.puts("요약: #{s}")
after
  60_000 -> IO.puts("(timeout)")
end
