defmodule ElGraphWeb.Guardrails do
  @moduledoc """
  들어오는 요청 텍스트에 입력 가드레일(`ElGraph.Guardrail`)을 적용하는 공용 헬퍼.

  가드 목록은 `conn.assigns[:guardrails]`로 주입된다(`ElGraphWeb.Endpoint`). 목록이
  비어 있으면 검사를 건너뛴다(기존 동작). 차단되면 `{:blocked, reason}`을 반환한다 —
  라우터가 프로토콜에 맞는 에러 응답(JSON-RPC -32602 / HTTP 403)으로 변환한다.
  """

  @doc """
  `conn.assigns[:guardrails]`(없으면 `[]`)를 `text`에 적용한다.
  통과 시 `{:ok, value}`, 차단 시 `{:blocked, reason}`.
  """
  @spec check(Plug.Conn.t(), String.t()) :: {:ok, term()} | {:blocked, term()}
  def check(conn, text) do
    ElGraph.Guardrail.check(conn.assigns[:guardrails] || [], text)
  end
end
