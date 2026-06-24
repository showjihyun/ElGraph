defmodule ElTraceWeb.HandoffLive do
  @moduledoc """
  멀티 에이전트 핸드오프 그래프 UI — "누가 어떤 시그널로 누구에게 넘겼는가"를
  서버사이드 SVG 그래프(JS 의존 0) + 엣지 표 + Graphviz DOT 소스로 보여준다.

  앱이 띄운 싱글턴 컬렉터(`ElTrace.handoff_graph/0`)에서 그래프를 읽는다.
  실시간 갱신: connected?면 2초마다 self()에 `:refresh`를 보내 다시 읽는다
  (컬렉터와 결합하지 않고 주기적으로 폴링한다).
  """
  use ElTraceWeb, :live_view

  alias ElTrace.Handoff

  @refresh_interval 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    {:ok,
     socket
     |> assign(
       page_title: "ElTrace — Handoff",
       active_page: :handoff,
       connected: connected?(socket)
     )
     |> load_graph()}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load_graph(socket)}

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, load_graph(socket)}
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval)

  defp load_graph(socket) do
    graph = ElTrace.handoff_graph()

    socket
    |> assign(
      nodes: graph.nodes,
      edges: graph.edges,
      svg: Handoff.to_svg(graph),
      dot: Handoff.to_dot(graph)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <p class="subtitle">
      멀티 에이전트 핸드오프 그래프 · 에이전트 <%= length(@nodes) %> · 핸드오프 <%= length(@edges) %>
      <span style="color: var(--muted)"> · 2초마다 자동 갱신</span>
    </p>

    <button class="btn" phx-click="refresh">↻ Refresh</button>

    <%!-- viz.js(클라이언트 Graphviz)가 있으면 DOT을 SVG로 렌더해 #handoff-server-svg를 숨긴다.
         없으면 아래 서버사이드 SVG가 그대로 보인다(JS/외부 의존 0 폴백). --%>
    <div :if={@edges != []} id="handoff-viz" phx-hook="DotGraph" data-dot={@dot} data-fallback="handoff-server-svg">
      <div id="handoff-viz-target" data-viz-target phx-update="ignore"></div>
    </div>

    <div :if={@edges != []} id="handoff-server-svg" class="handoff-graph"><%= raw(@svg) %></div>

    <table class="handoff">
      <thead>
        <tr>
          <th>From</th>
          <th>Signal</th>
          <th>To</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={e <- @edges}>
          <td class="from"><%= e.from %></td>
          <td class="signal"><%= e.signal %></td>
          <td class="to"><%= e.to %></td>
        </tr>
      </tbody>
    </table>

    <p :if={@edges == []} class="empty">
      <span class="empty-icon">🕸️</span>아직 핸드오프가 없습니다.
    </p>

    <details class="dot-source">
      <summary>Graphviz DOT 소스</summary>
      <pre class="dot"><%= @dot %></pre>
    </details>
    """
  end
end
