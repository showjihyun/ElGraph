defmodule ElGraph.Presets do
  @moduledoc """
  미리 조립된 그래프 프리셋 — "첫 5분 경험" (SPEC §4, 부록 A-3).

      llm = {MyAdapter, config}
      graph = ElGraph.Presets.react(llm, [MyApp.SearchAction])
      {:ok, %{messages: messages}} =
        ElGraph.invoke(graph, %{messages: [ElGraph.LLM.user("질문")]})
  """

  @doc """
  ReAct 에이전트 그래프: agent(LLM 호출) ↔ tools 루프.

  `tools`는 Action 모듈과 `ElGraph.MCP.Tool`을 섞어 쓸 수 있다.
  옵션: `:system`(시스템 프롬프트).
  """
  @spec react({module(), term()}, [module() | ElGraph.MCP.Tool.t()], keyword()) ::
          ElGraph.Graph.t()
  def react(llm, tools, opts \\ []), do: ElGraph.Presets.ReAct.build(llm, tools, opts)
end
