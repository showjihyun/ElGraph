defmodule ElGraph.Nodes.Summarize do
  @moduledoc """
  컨텍스트 압축 노드 (SPEC §4, M4). 긴 대화의 오래된 메시지를 LLM 요약으로 치환한다.

  그래프 노드로 끼운다 (보통 agent 직전):

      |> ElGraph.add_node(:compact,
           {ElGraph.Nodes.Summarize, :run, [[
             llm: {ElGraph.LLM.OpenAI, api_key: key},
             trigger: {:messages, 20},   # messages가 20개 초과면 압축
             keep: {:messages, 6},        # 최근 6개는 원문 유지
             store: {Store.ETS, store_config, ["conversations", "c1"]}  # 축출분 보관(선택)
           ]]})

  `:messages` 채널이 `ElGraph.Reducers.append` reducer일 때 동작한다(노드가
  `{:replace, list}` 마커로 채널을 치환한다). living summary: [요약 메시지 | 최근 N개].
  """

  alias ElGraph.LLM

  @summary_prompt "다음은 이전 대화의 오래된 부분이다. 핵심 정보·결정·맥락을 보존해 " <>
                    "한국어로 간결히 요약하라. 이후 대화가 이 요약에 의존한다."

  @doc false
  def run(%{messages: messages}, _ctx, opts) do
    {:messages, trigger} = Keyword.fetch!(opts, :trigger)

    if length(messages) > trigger do
      compact(messages, opts)
    else
      %{}
    end
  end

  defp compact(messages, opts) do
    {:messages, keep_n} = Keyword.fetch!(opts, :keep)
    {evict, keep} = Enum.split(messages, length(messages) - keep_n)

    summary = summarize(evict, Keyword.fetch!(opts, :llm))
    maybe_store(evict, Keyword.get(opts, :store))

    %{messages: {:replace, [summary | keep]}}
  end

  defp summarize(evict, {llm_mod, llm_config}) do
    transcript = Enum.map_join(evict, "\n", fn m -> "#{m.role}: #{m.content}" end)

    case llm_mod.chat(llm_config, [LLM.user("#{@summary_prompt}\n\n#{transcript}")], []) do
      {:ok, %{message: %{content: content}}} ->
        %{role: :system, content: "[이전 대화 요약] #{content}"}

      {:error, reason} ->
        raise ElGraph.LLMError, reason: reason
    end
  end

  defp maybe_store(_evict, nil), do: :ok

  defp maybe_store(evict, {store_mod, store_config, namespace}) do
    key = "evicted-#{System.unique_integer([:positive, :monotonic])}"
    store_mod.put(store_config, namespace, key, evict)
  end
end
