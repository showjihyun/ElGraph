defmodule ElGraph.Memory.Backend do
  @moduledoc """
  교체 가능한 기억 백엔드 behaviour — "기억 저장 + 의미 검색" 두 동작만 추상화한다.

  좁은 경계로 둔 이유: Mem0/Zep 같은 외부 메모리 서비스가 잘하는 건 *remember + recall*
  뿐이다. ElGraph의 구조화된 사실(`ElGraph.Memory`의 3-스코프·시점진실·temporal·충돌해소)은
  차별점이라 외부에 위임하지 않고 코어에 남긴다 — 이 behaviour는 그 위에 얹는 시맨틱 회수 층이다.

    * `ElGraph.Memory.Backend.Native` — 코어 임베더(`recall_relevant`) 기반 (외부 의존 0)
    * `ElGraph.Memory.Backend.Mem0` — Mem0 REST API 위임

  `{module, config}` 핸들로 디스패치한다(체크포인터/Store와 동일 패턴):

      backend = {ElGraph.Memory.Backend.Mem0, api_key: "..."}
      ElGraph.Memory.Backend.remember(backend, ["users", "u1"], "user upgraded to pro")
      {:ok, hits} = ElGraph.Memory.Backend.recall(backend, ["users", "u1"], "what plan?")
  """

  @type config :: term()
  @type handle :: {module(), config()}
  @type namespace :: [String.t()]

  @doc "기억 한 건을 저장한다."
  @callback remember(config(), namespace(), text :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc "쿼리와 의미적으로 가까운 기억들의 텍스트를 회수한다."
  @callback recall(config(), namespace(), query :: String.t(), opts :: keyword()) ::
              {:ok, [String.t()]} | {:error, term()}

  @doc "백엔드 핸들로 `remember`를 디스패치한다."
  @spec remember(handle(), namespace(), String.t(), keyword()) :: :ok | {:error, term()}
  def remember({mod, config}, ns, text, opts \\ []), do: mod.remember(config, ns, text, opts)

  @doc "백엔드 핸들로 `recall`을 디스패치한다."
  @spec recall(handle(), namespace(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def recall({mod, config}, ns, query, opts \\ []), do: mod.recall(config, ns, query, opts)
end
