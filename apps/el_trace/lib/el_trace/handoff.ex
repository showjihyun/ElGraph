defmodule ElTrace.Handoff do
  @moduledoc """
  멀티 에이전트 핸드오프 그래프 — "누가 어떤 시그널로 누구에게 넘겼는가".

  el_graph의 `[:el_graph, :agent, :handoff]` 텔레메트리(수신 에이전트가 발행하는
  완성된 엣지 `source --signal--> this_agent`)를 모은 엣지 목록을 받아 노드/엣지 그래프로
  만들고, Graphviz DOT 또는 텍스트로 렌더한다 (순수 함수 — 데이터/제어 평면 우선).

  LiveView로 DOT을 그리는 것은 후속 작업이다.
  """

  @type edge :: %{from: String.t(), to: String.t(), signal: String.t()}
  @type graph :: %{nodes: [String.t()], edges: [edge()]}

  @doc """
  엣지 목록에서 그래프를 만든다. 노드는 from/to에서 모은 유일한 에이전트 id를 정렬한 것,
  엣지는 동일한 (from, to, signal) 삼중을 하나로 합친 것이다.
  """
  @spec build([edge()]) :: graph()
  def build(edges) do
    deduped = Enum.uniq(edges)

    nodes =
      deduped
      |> Enum.flat_map(fn %{from: from, to: to} -> [from, to] end)
      |> Enum.uniq()
      |> Enum.sort()

    %{nodes: nodes, edges: deduped}
  end

  @doc "그래프를 Graphviz DOT digraph 문자열로 렌더한다."
  @spec to_dot(graph()) :: String.t()
  def to_dot(%{edges: edges}) do
    lines =
      Enum.map_join(edges, "\n", fn %{from: from, to: to, signal: signal} ->
        ~s(  "#{from}" -> "#{to}" [label="#{signal}"];)
      end)

    "digraph handoff {\n" <> lines <> "\n}"
  end

  @doc "그래프를 사람이 읽는 텍스트 줄(`a --signal--> b`)로 렌더한다."
  @spec render(graph()) :: String.t()
  def render(%{edges: edges}) do
    Enum.map_join(edges, "\n", fn %{from: from, to: to, signal: signal} ->
      "#{from} --#{signal}--> #{to}"
    end)
  end
end
