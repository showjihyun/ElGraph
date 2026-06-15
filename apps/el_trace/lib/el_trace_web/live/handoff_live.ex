defmodule ElTraceWeb.HandoffLive do
  @moduledoc """
  멀티 에이전트 핸드오프 그래프 UI — "누가 어떤 시그널로 누구에게 넘겼는가"를
  엣지 표와 Graphviz DOT 소스로 보여준다.

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

    {:ok, socket |> assign(:page_title, "ElTrace — Handoff") |> load_graph()}
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
    |> assign(nodes: graph.nodes, edges: graph.edges, dot: Handoff.to_dot(graph))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1 class="title">ElTrace — Handoff</h1>
    <p class="subtitle">멀티 에이전트 핸드오프 그래프 · 에이전트 <%= length(@nodes) %> · 핸드오프 <%= length(@edges) %></p>

    <button class="btn" phx-click="refresh">Refresh</button>

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

    <p :if={@edges == []} class="empty">아직 핸드오프가 없습니다.</p>

    <h2>Graphviz DOT</h2>
    <pre class="dot"><%= @dot %></pre>
    """
  end
end
