defmodule ElGraph.Demo.DocsAgent do
  @moduledoc """
  도그푸딩 에이전트 1호: 문서 검색 Q&A. `ElGraph.Skills.SignalReAct`로 재구성됨 (M4).

  `"question.asked"` 시그널의 `data.question`을 받아 문서 검색 ReAct 루프를 돌고,
  `reply_to`에 `{:demo_answer, %{answer:, usage:}}`를 보낸다.
  """

  use ElGraph.Skills.SignalReAct,
    route: "question.*",
    input_key: :question,
    tools: [ElGraph.Demo.DocsSearch],
    reply_tag: :demo_answer,
    budget: [tokens: 200_000],
    system:
      "너는 ElGraph 프로젝트의 문서 안내 봇이다. 질문에 답하기 전에 반드시 docs_search 툴로 " <>
        "문서를 검색하고, 검색 결과에 근거해 한국어로 간결하게 답하라. " <>
        "검색 결과가 비거나 부족하면 포기하지 말고 더 짧고 핵심적인 키워드로 1~2번 다시 검색하라. " <>
        "그래도 근거가 없으면 모른다고 답하라."

  # 기본 LLM(실 OpenAI)을 주입한 뒤 Skill의 start_link으로 위임한다.
  def start_link(opts) do
    llm =
      Keyword.get_lazy(opts, :llm, fn ->
        {ElGraph.LLM.OpenAI, api_key: ElGraph.Demo.fetch_api_key!()}
      end)

    super(Keyword.put(opts, :llm, llm))
  end
end
