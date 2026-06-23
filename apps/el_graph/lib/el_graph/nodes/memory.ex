defmodule ElGraph.Nodes.Memory do
  @moduledoc """
  `ElGraph.Memory`를 그래프 노드로 끼우는 헬퍼 (트렌드 보고서 Tier 2.6).

  `Memory`는 그 자체로는 스탠드얼론 계층이다 — 이 모듈이 그것을 그래프 런타임의 노드로
  연결한다. 빌더는 MFA(`{__MODULE__, :recall, [{memory, ns, opts}]}`)를 돌려주므로
  durable 그래프(체크포인트 재개)와 호환된다 (SPEC §3.2).

      graph
      |> ElGraph.add_node(:remember, ElGraph.Nodes.Memory.record_node(mem, ["users", "u1"]))
      |> ElGraph.add_node(:recall, ElGraph.Nodes.Memory.recall_node(mem, ["users", "u1"]))

  ## recall_node 옵션

    * `:into` — 회수 결과를 넣을 상태 키 (기본 `:recalled`)
    * `:limit` — 회수 개수 상한
    * `:embedder` — 주면 `:query_key` 상태 필드를 쿼리로 시맨틱 회수(`recall_relevant/4`)
    * `:query_key` — 시맨틱 회수 쿼리를 읽을 상태 키 (기본 `:query`)
    * `:scope` — 시맨틱 회수 스코프 (기본 `"episodic"`)

  ## record_node 옵션

    * `:from` — 기록할 값을 읽을 상태 키. 기본은 `:messages`의 마지막 메시지 content.
  """

  alias ElGraph.Memory

  @type ns :: Memory.namespace()
  @type mfa_node :: {module(), atom(), [term()]}

  @doc "관련 기억을 상태 키(기본 `:recalled`)로 회수하는 노드 MFA를 만든다."
  @spec recall_node(Memory.t(), ns(), keyword()) :: mfa_node()
  def recall_node(%Memory{} = memory, ns, opts \\ []),
    do: {__MODULE__, :recall, [{memory, ns, opts}]}

  @doc "상태에서 에피소드를 기록하는 노드 MFA를 만든다."
  @spec record_node(Memory.t(), ns(), keyword()) :: mfa_node()
  def record_node(%Memory{} = memory, ns, opts \\ []),
    do: {__MODULE__, :record, [{memory, ns, opts}]}

  @doc false
  @spec recall(map(), ElGraph.Ctx.t(), {Memory.t(), ns(), keyword()}) :: map()
  def recall(state, _ctx, {memory, ns, opts}) do
    into = Keyword.get(opts, :into, :recalled)
    %{into => do_recall(memory, ns, state, opts)}
  end

  @doc false
  @spec record(map(), ElGraph.Ctx.t(), {Memory.t(), ns(), keyword()}) :: map()
  def record(state, _ctx, {memory, ns, opts}) do
    case extract_event(state, opts) do
      nil -> %{}
      # 직렬화 불가 이벤트면 {:error}가 올 수 있다 — 노드는 크래시 없이 기록을 건너뛴다.
      event -> Memory.record_episode(memory, ns, event)
    end

    %{}
  end

  defp do_recall(memory, ns, state, opts) do
    case Keyword.get(opts, :embedder) do
      nil ->
        Memory.recall_episodes(memory, ns, take_limit(opts))

      embedder ->
        query_key = Keyword.get(opts, :query_key, :query)

        recall_opts =
          [embedder: embedder, scope: Keyword.get(opts, :scope, "episodic")] ++ take_limit(opts)

        Memory.recall_relevant(memory, ns, Map.get(state, query_key), recall_opts)
    end
  end

  defp take_limit(opts) do
    case Keyword.get(opts, :limit) do
      nil -> []
      limit -> [limit: limit]
    end
  end

  defp extract_event(state, opts) do
    case Keyword.get(opts, :from) do
      nil -> last_message_content(state)
      key -> Map.get(state, key)
    end
  end

  defp last_message_content(%{messages: messages}) when is_list(messages) do
    case List.last(messages) do
      %{content: content} -> content
      _ -> nil
    end
  end

  defp last_message_content(_state), do: nil
end
