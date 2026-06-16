defmodule ElGraph.Signal do
  @moduledoc """
  에이전트 간 메시지 (SPEC §5). CloudEvents 핵심 필드를 따른다.

  타입은 점 구분 문자열(`"task.assigned"`)이며 `matches?/2`로 패턴 매칭한다:
  정확 일치, 접두 와일드카드(`"task.*"`), 전체(`"*"`).
  """

  @enforce_keys [:type]
  defstruct [:type, :source, :subject, :data, :id]

  @type t :: %__MODULE__{
          type: String.t(),
          source: String.t() | nil,
          subject: String.t() | nil,
          data: term(),
          id: String.t() | nil
        }

  @doc """
  전달 id를 보장한다(CloudEvents `id`) — 없으면 생성, 있으면 보존한다.

  버스는 발행 시 fan-out **전에** 한 번 스탬프하므로, 같은 시그널의 모든 수신본(원격 노드 포함)이
  동일 id를 갖는다. 수신 측은 이 id로 멱등 처리(`ElGraph.Signal.Dedup`)해 at-least-once
  재전달(예: netsplit 회복)을 안전하게 무시한다 (SPEC §6).
  """
  @spec ensure_id(t()) :: t()
  def ensure_id(%__MODULE__{id: id} = signal) when is_binary(id), do: signal

  def ensure_id(%__MODULE__{} = signal),
    do: %{signal | id: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)}

  @doc "시그널 타입이 패턴에 매칭되는지 — 정확 일치 / `prefix.*` / `*`."
  @spec matches?(String.t(), String.t()) :: boolean()
  def matches?("*", _type), do: true

  def matches?(pattern, type) do
    case String.split_at(pattern, -2) do
      {prefix, ".*"} -> String.starts_with?(type, prefix <> ".")
      _no_wildcard -> pattern == type
    end
  end
end
