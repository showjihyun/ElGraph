defmodule ElGraph.Store do
  @moduledoc """
  thread를 넘는 장기 기억 behaviour (SPEC §6).

  체크포인터가 thread 단위 단기 기억이라면, Store는 thread를 가로지르는 기억
  (사용자 선호, 누적 사실, 대화 요약 축출분 등)이다. LangGraph의 BaseStore에 해당.

  namespace로 계층 분리한다 — 예: `["users", "u1"]`. 어댑터 적합성은 공유 계약
  테스트(`ElGraph.StoreContract`)로 검증하며, 시맨틱 검색은 표본이 나오면 추가한다.
  """

  @type config :: term()
  @type namespace :: [String.t()]
  @type key :: String.t()

  @callback put(config(), namespace(), key(), value :: term()) :: :ok | {:error, term()}
  @callback get(config(), namespace(), key()) :: {:ok, term()} | :not_found
  @callback delete(config(), namespace(), key()) :: :ok
  @callback list(config(), namespace()) :: [{key(), term()}]
end
