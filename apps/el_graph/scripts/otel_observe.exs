# ElTrace 도그푸딩: 다양한 실행 패턴을 Langfuse로 보내 "무엇이 관측되나" 관찰
#   mix run scripts/otel_observe.exs
#
# 시나리오 A: HITL (interrupt_before → resume) — 두 invoke, 같은 thread_id
# 시나리오 B: 멀티 에이전트 파이프라인 (Researcher → Bus → Summarizer) — 에이전트별 별도 프로세스

alias ElGraph.OTel.Bridge
alias ElGraph.Signal
alias ElGraph.Signal.Bus
alias ElGraph.Checkpointer.ETS

secrets =
  if File.exists?("config/secrets.exs") do
    {s, _} = Code.eval_file("config/secrets.exs")
    s
  else
    []
  end

otlp =
  Bridge.langfuse_otlp_config(
    secrets[:langfuse_public_key],
    secrets[:langfuse_secret_key],
    endpoint: secrets[:langfuse_endpoint]
  )

Application.stop(:opentelemetry)
Application.put_env(:opentelemetry_exporter, :otlp_protocol, otlp[:otlp_protocol])
Application.put_env(:opentelemetry_exporter, :otlp_endpoint, otlp[:otlp_endpoint])
Application.put_env(:opentelemetry_exporter, :otlp_headers, otlp[:otlp_headers])
Application.put_env(:opentelemetry, :span_processor, :batch)
Application.put_env(:opentelemetry, :traces_exporter, :otlp)
{:ok, _} = Application.ensure_all_started(:opentelemetry_exporter)
{:ok, _} = Application.ensure_all_started(:opentelemetry)
:ok = Bridge.attach()

llm = {ElGraph.LLM.OpenAI, api_key: ElGraph.Demo.fetch_api_key!()}

## 시나리오 A — HITL: 툴 실행 전 멈췄다가 재개
IO.puts("\n=== A: HITL (interrupt_before → resume) ===")
{:ok, cp_pid} = ETS.start_link()
cp = {ETS, ETS.config(cp_pid)}
tid = "hitl-#{System.os_time(:second)}"

graph_a =
  ElGraph.Presets.react(llm, [ElGraph.Demo.DocsSearch],
    system: "반드시 docs_search 툴을 호출해 답하라."
  )

input_a = %{messages: [ElGraph.LLM.user("체크포인트 보존 정책은?")]}

case ElGraph.invoke(graph_a, input_a, checkpointer: cp, thread_id: tid, interrupt_before: [:tools]) do
  {:interrupted, info} ->
    IO.puts("  멈춤: before=#{inspect(info.before)} (thread #{tid})")
    {:ok, _} = ElGraph.resume(graph_a, checkpointer: cp, thread_id: tid)
    IO.puts("  재개 완료")

  {:ok, _} ->
    IO.puts("  (인터럽트 없이 완료 — 모델이 툴을 안 불렀음)")
end

## 시나리오 B — 멀티 에이전트 파이프라인
IO.puts("\n=== B: 멀티 에이전트 (Researcher → Bus → Summarizer) ===")

defmodule Obs.Researcher do
  use ElGraph.Skills.SignalReAct,
    route: "question.*",
    input_key: :question,
    tools: [ElGraph.Demo.DocsSearch],
    reply_tag: :research_done,
    system: "docs_search로 검색해 핵심을 정리하라."
end

defmodule Obs.Summarizer do
  use ElGraph.Skills.SignalReAct,
    route: "research.done",
    input_key: :answer,
    tools: [],
    reply_tag: :final,
    system: "한 문장으로 요약하라."
end

{:ok, _} = Bus.start_link(name: ObsBus)
{:ok, _} = Obs.Researcher.start_link(llm: llm, id: "r", subscribe: {ObsBus, "question.*"}, emit: {ObsBus, "research.done"})
{:ok, _} = Obs.Summarizer.start_link(llm: llm, id: "s", subscribe: {ObsBus, "research.done"}, reply_to: self())

Bus.publish(ObsBus, %Signal{type: "question.asked", data: %{question: "ElGraph의 인터럽트는?"}})

receive do
  {:final, %{answer: a}} -> IO.puts("  파이프라인 완료: #{a}")
after
  60_000 -> IO.puts("  (timeout)")
end

IO.puts("\nflush 대기 (6초)...")

receive do
after
  6_000 -> :ok
end

IO.puts("완료. thread_id(HITL)=#{tid}")
