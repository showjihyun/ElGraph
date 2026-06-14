defmodule ElGraph.Guardrail.PII do
  @moduledoc """
  자주 쓰는 PII(개인식별정보) 패턴 라이브러리.

  컴파일된 정규식을 한 곳에서 제공해 `ElGraph.Guardrail`의 `redact_pii/2`, `deny_pii/1`
  가드가 일관된 탐지 규칙을 쓰도록 한다. 휴리스틱이므로 완벽한 탐지를 보장하진 않는다.
  """

  @patterns %{
    email: ~r/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/,
    phone: ~r/\+?\d[\d\s().-]{7,}\d/,
    credit_card: ~r/\b(?:\d[ -]?){13,16}\b/,
    ssn: ~r/\b\d{3}-\d{2}-\d{4}\b/,
    rrn: ~r/\b\d{6}-\d{7}\b/,
    ipv4: ~r/\b(?:\d{1,3}\.){3}\d{1,3}\b/
  }

  @doc "키별 컴파일된 PII 정규식 맵을 반환한다."
  @spec patterns() :: %{atom() => Regex.t()}
  def patterns, do: @patterns

  @doc "단일 PII 타입의 컴파일된 정규식을 반환한다."
  @spec pattern(atom()) :: Regex.t()
  def pattern(type) when is_atom(type), do: Map.fetch!(@patterns, type)
end
