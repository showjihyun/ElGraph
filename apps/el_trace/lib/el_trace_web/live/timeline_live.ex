defmodule ElTraceWeb.TimelineLive do
  @moduledoc """
  ElTrace 타임라인 UI. thread 생애(체크포인트 체인)를 실시간으로 보여주고,
  인터럽트에서 승인/거절(resume), 임의 step에서 "여기서 분기"(Replay)를 제공한다.

  실시간: 실행 텔레메트리 → `ElTrace.Telemetry` → PubSub(thread별 토픽) → 자동 재렌더.
  무거운 작업(resume/Replay)은 `start_async`로 분리해 LiveView 프로세스를 막지 않는다.
  """
  use ElTraceWeb, :live_view

  alias ElTrace.{Sessions, Telemetry, Timeline, Replay}

  @impl true
  def mount(_params, _session, socket) do
    table = Sessions.table(Sessions)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(ElTrace.PubSub, Sessions.sessions_topic())
    end

    socket =
      socket
      |> assign(table: table, selected: nil, events: [], page_title: "ElTrace")
      |> load_sessions()

    {:ok, socket}
  end

  @impl true
  def handle_event("select", %{"thread" => tid}, socket) do
    {:noreply, select_thread(socket, tid)}
  end

  def handle_event("approve", _params, socket), do: {:noreply, resume(socket, "approved")}
  def handle_event("reject", _params, socket), do: {:noreply, resume(socket, "rejected")}

  def handle_event("branch", %{"step" => step}, socket) do
    tid = socket.assigns.selected

    case Sessions.get(socket.assigns.table, tid) do
      {:ok, %{graph: graph, checkpointer: cp}} ->
        step = String.to_integer(step)
        fork = "#{tid}-fork-#{step}"
        table = socket.assigns.table

        socket =
          start_async(socket, {:branch, fork}, fn ->
            result = Replay.from(cp, tid, step, graph, as: fork)
            Sessions.register(table, fork, graph, cp, parent: tid)
            result
          end)

        {:noreply, socket}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:resume, tid}, {:ok, _result}, socket) do
    {:noreply, if(tid == socket.assigns.selected, do: load_timeline(socket), else: socket)}
  end

  def handle_async({:resume, _tid}, {:exit, reason}, socket) do
    {:noreply, put_flash(socket, :error, "resume 실패: #{inspect(reason)}")}
  end

  def handle_async({:branch, _fork}, {:ok, _result}, socket) do
    {:noreply, load_sessions(socket)}
  end

  def handle_async({:branch, _fork}, {:exit, reason}, socket) do
    {:noreply, put_flash(socket, :error, "분기 실패: #{inspect(reason)}")}
  end

  @impl true
  def handle_info({:thread_event, %{thread_id: tid}}, socket) do
    {:noreply, if(tid == socket.assigns.selected, do: load_timeline(socket), else: socket)}
  end

  def handle_info(:sessions_changed, socket), do: {:noreply, load_sessions(socket)}

  ## 내부

  defp resume(socket, value) do
    tid = socket.assigns.selected

    case Sessions.get(socket.assigns.table, tid) do
      {:ok, %{graph: graph, checkpointer: cp}} ->
        start_async(socket, {:resume, tid}, fn ->
          ElGraph.resume(graph, checkpointer: cp, thread_id: tid, resume: value)
        end)

      :error ->
        socket
    end
  end

  defp select_thread(socket, tid) do
    if prev = socket.assigns.selected do
      Phoenix.PubSub.unsubscribe(ElTrace.PubSub, Telemetry.thread_topic(prev))
    end

    Phoenix.PubSub.subscribe(ElTrace.PubSub, Telemetry.thread_topic(tid))

    socket |> assign(:selected, tid) |> load_timeline()
  end

  defp load_sessions(socket), do: assign(socket, :sessions, Sessions.list(socket.assigns.table))

  defp load_timeline(socket) do
    case Sessions.get(socket.assigns.table, socket.assigns.selected) do
      {:ok, %{checkpointer: cp}} ->
        assign(socket, :events, Timeline.build(cp, socket.assigns.selected))

      :error ->
        assign(socket, :events, [])
    end
  end

  defp kind_label(:start), do: "start"
  defp kind_label(:step), do: "step"
  defp kind_label(:interrupt), do: "⏸ interrupt"
  defp kind_label(:done), do: "✓ done"

  @impl true
  def render(assigns) do
    ~H"""
    <h1 class="title">ElTrace</h1>
    <p class="subtitle">체크포인트 타임라인 · 승인/거절 · 여기서 분기</p>

    <div class="layout">
      <aside class="sessions">
        <h2>Threads</h2>
        <p :if={@sessions == []} class="empty">등록된 실행이 없습니다.</p>
        <button
          :for={s <- @sessions}
          class={["session", s.thread_id == @selected && "active"]}
          phx-click="select"
          phx-value-thread={s.thread_id}
        >
          <div class="tid"><%= s.thread_id %></div>
          <div :if={s.parent} class="fork">⑂ from <%= s.parent %></div>
        </button>
      </aside>

      <section class="timeline">
        <%= if @selected do %>
          <h2><%= @selected %></h2>
          <div :for={e <- @events} class={["event", to_string(e.kind)]}>
            <span class="dot"></span>
            <div class="head">
              <span class="step-no">step <%= e.step %></span>
              <span class="kind"><%= kind_label(e.kind) %></span>
              <span :if={e[:node]} class="node">@<%= e.node %></span>
              <span :if={e[:next]} class="next">→ <%= inspect(e.next) %></span>
            </div>
            <pre :if={e[:payload]} class="payload"><%= inspect(e.payload, pretty: true) %></pre>
            <div class="actions">
              <%= if e.kind == :interrupt do %>
                <button class="btn btn-approve" phx-click="approve">승인</button>
                <button class="btn btn-reject" phx-click="reject">거절</button>
              <% end %>
              <button class="btn btn-branch small" phx-click="branch" phx-value-step={e.step}>
                여기서 분기
              </button>
            </div>
          </div>
        <% else %>
          <p class="empty">왼쪽에서 thread를 선택하세요.</p>
        <% end %>
      </section>
    </div>
    """
  end
end
