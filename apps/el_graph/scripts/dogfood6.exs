# 도그푸딩 세션 7: 멀티 에이전트 파이프라인 (핸드오프, 실 OpenAI)
#   mix run scripts/dogfood6.exs
#
# Researcher(문서 검색) --research.done--> Bus --> Summarizer(요약) --> 사용자
# 두 에이전트가 버스로만 연결되어 서로를 모른다 (핸드오프 = emit + subscribe).

alias ElGraph.Signal
alias ElGraph.Signal.Bus
alias ElGraph.Demo.DocsSearch

defmodule Pipe.Researcher do
  use ElGraph.Skills.SignalReAct,
    route: "question.*",
    input_key: :question,
    tools: [DocsSearch],
    reply_tag: :research_done,
    system: "문서를 docs_search로 검색해 질문에 대한 핵심 사실을 모아 정리하라."
end

defmodule Pipe.Summarizer do
  use ElGraph.Skills.SignalReAct,
    route: "research.done",
    input_key: :answer,
    tools: [],
    reply_tag: :final,
    system: "받은 조사 내용을 한 문장으로 요약하라."
end

key = ElGraph.Demo.fetch_api_key!()
llm = {ElGraph.LLM.OpenAI, api_key: key}

{:ok, _} = Bus.start_link(name: PipeBus)

{:ok, _} =
  Pipe.Researcher.start_link(
    llm: llm,
    id: "researcher",
    subscribe: {PipeBus, "question.*"},
    emit: {PipeBus, "research.done"}
  )

{:ok, _} =
  Pipe.Summarizer.start_link(
    llm: llm,
    id: "summarizer",
    subscribe: {PipeBus, "research.done"},
    reply_to: self()
  )

IO.puts("2-에이전트 파이프라인 가동 (Researcher → Bus → Summarizer)")
IO.puts("질문 발행: 'ElGraph의 인터럽트는 어떻게 동작해?'\n")

Bus.publish(PipeBus, %Signal{type: "question.asked", data: %{question: "ElGraph의 인터럽트는 어떻게 동작해?"}})

receive do
  {:final, %{answer: answer, usage: usage}} ->
    IO.puts("[파이프라인 완료 — 에이전트들이 서로를 모른 채 버스로 협업]")
    IO.puts("최종 요약: #{answer}")
    IO.puts("(Summarizer 단계 tokens in/out: #{usage.input_tokens}/#{usage.output_tokens})")
after
  90_000 -> IO.puts("(timeout)")
end
