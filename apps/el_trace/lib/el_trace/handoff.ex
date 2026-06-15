defmodule ElTrace.Handoff do
  @moduledoc """
  멀티 에이전트 핸드오프 그래프 — "누가 어떤 시그널로 누구에게 넘겼는가".

  el_graph의 `[:el_graph, :agent, :handoff]` 텔레메트리(수신 에이전트가 발행하는
  완성된 엣지 `source --signal--> this_agent`)를 모은 엣지 목록을 받아 노드/엣지 그래프로
  만들고, **서버사이드 SVG**(`to_svg/1`)·Graphviz DOT(`to_dot/1`)·텍스트(`render/1`)로 렌더한다
  (전부 순수 함수). SVG는 `ElTraceWeb.HandoffLive`(`/handoff`)가 인라인으로 그린다 — JS 의존 0.
  """

  @type edge :: %{from: String.t(), to: String.t(), signal: String.t()}
  @type graph :: %{nodes: [String.t()], edges: [edge()]}

  @doc """
  엣지 목록에서 그래프를 만든다. 노드는 from/to에서 모은 유일한 에이전트 id를 정렬한 것,
  엣지는 동일한 (from, to, signal) 삼중을 하나로 합친 것이다.

      iex> ElTrace.Handoff.build([%{from: "b", to: "a", signal: "s"}]).nodes
      ["a", "b"]
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

  @doc """
  그래프를 사람이 읽는 텍스트 줄(`a --signal--> b`)로 렌더한다.

      iex> ElTrace.Handoff.render(ElTrace.Handoff.build([%{from: "a", to: "b", signal: "go"}]))
      "a --go--> b"
  """
  @spec render(graph()) :: String.t()
  def render(%{edges: edges}) do
    Enum.map_join(edges, "\n", fn %{from: from, to: to, signal: signal} ->
      "#{from} --#{signal}--> #{to}"
    end)
  end

  # SVG 레이아웃 상수
  @node_w 130
  @node_h 40
  @gap 70
  @pad 24
  @node_y 150

  @doc """
  그래프를 **서버사이드 SVG**로 렌더한다 — 브라우저에 실제 그래프를 그린다(JS/외부 의존 0).

  노드는 한 행에 둥근 사각형으로 배치하고, 엣지는 위쪽 호(arc) + 화살표 + 시그널 라벨로
  그린다. self-loop은 노드 위 작은 고리. 오프라인·자급식 관측에 적합하며 `Phoenix.HTML.raw/1`로
  LiveView에 그대로 임베드한다. (클라이언트 Graphviz 렌더가 필요하면 `to_dot/1` + viz.js 훅을 쓴다.)
  """
  @spec to_svg(graph()) :: String.t()
  def to_svg(%{nodes: nodes, edges: edges}) do
    index = nodes |> Enum.with_index() |> Map.new()
    width = max(@pad * 2 + length(nodes) * (@node_w + @gap), @node_w + @pad * 2)
    height = 220

    edge_svg = Enum.map_join(edges, "\n", &edge_svg(&1, index))
    node_svg = Enum.map_join(nodes, "\n", &node_svg(&1, index))

    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{width} #{height}" width="100%" role="img" aria-label="handoff graph">
      <defs>
        <marker id="el-arrow" markerWidth="10" markerHeight="10" refX="8" refY="4" orient="auto">
          <path d="M0,0 L9,4 L0,8 z" fill="#557"/>
        </marker>
      </defs>
    #{edge_svg}
    #{node_svg}
    </svg>
    """
  end

  defp cx(idx), do: @pad + idx * (@node_w + @gap) + div(@node_w, 2)

  defp node_svg(name, index) do
    x = @pad + index[name] * (@node_w + @gap)
    tx = x + div(@node_w, 2)

    ~s|  <rect x="#{x}" y="#{@node_y}" width="#{@node_w}" height="#{@node_h}" rx="6" fill="#eef2ff" stroke="#557"/>| <>
      ~s|\n  <text x="#{tx}" y="#{@node_y + 25}" text-anchor="middle" font-size="13" fill="#223">#{escape(name)}</text>|
  end

  defp edge_svg(%{from: from, to: to, signal: signal}, index) do
    fi = index[from]
    ti = index[to]
    edge_svg(fi, ti, signal)
  end

  # self-loop: 노드 위 작은 고리
  defp edge_svg(i, i, signal) do
    cx = cx(i)

    ~s|  <path class="edge" d="M #{cx - 18} #{@node_y} C #{cx - 30} #{@node_y - 55}, #{cx + 30} #{@node_y - 55}, #{cx + 18} #{@node_y}" fill="none" stroke="#557" marker-end="url(#el-arrow)"/>| <>
      ~s|\n  <text x="#{cx}" y="#{@node_y - 50}" text-anchor="middle" font-size="11" fill="#335">#{escape(signal)}</text>|
  end

  defp edge_svg(fi, ti, signal) do
    sx = cx(fi)
    ex = cx(ti)
    span = abs(ti - fi)
    ctrl_y = @node_y - (40 + span * 35)
    midx = div(sx + ex, 2)

    ~s|  <path class="edge" d="M #{sx} #{@node_y} Q #{midx} #{ctrl_y} #{ex} #{@node_y}" fill="none" stroke="#557" marker-end="url(#el-arrow)"/>| <>
      ~s|\n  <text x="#{midx}" y="#{ctrl_y + 12}" text-anchor="middle" font-size="11" fill="#335">#{escape(signal)}</text>|
  end

  defp escape(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
