defmodule ElGraph.Demo.SummarizeAgent do
  @moduledoc """
  도그푸딩 에이전트 2호: 툴 없는 순수 변환. `ElGraph.Skills.SignalReAct`로 재구성됨 (M4).

  `"text.submitted"` 시그널의 `data.text`를 받아 한 문장으로 요약하고,
  `reply_to`에 `{:summary, %{answer:, usage:}}`를 보낸다. 툴이 없어 단일 LLM 변환이다 —
  1호(Grounded Q&A)와 같은 Skill을 (툴 0개, 다른 라우트/프롬프트)로 재사용한다.
  """

  use ElGraph.Skills.SignalReAct,
    route: "text.submitted",
    input_key: :text,
    tools: [],
    reply_tag: :summary,
    budget: [tokens: 100_000],
    system: "너는 요약 봇이다. 입력 텍스트를 한국어 한 문장으로 간결히 요약하라."
end
