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
      |> assign(
        table: table,
        selected: nil,
        events: [],
        page_title: "ElTrace",
        active_page: :timeline,
        connected: connected?(socket)
      )
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

    # step은 클라이언트가 보내는 값 — 정수 파싱 실패/세션 없음이면 조용히 무시한다(크래시 금지).
    with {step, ""} <- Integer.parse(step),
         {:ok, %{graph: graph, checkpointer: cp}} <- Sessions.get(socket.assigns.table, tid) do
      fork = "#{tid}-fork-#{step}"
      table = socket.assigns.table

      socket =
        start_async(socket, {:branch, fork}, fn ->
          # 분기 실패 시 junk 세션을 등록하지 않는다.
          case Replay.from(cp, tid, step, graph, as: fork) do
            {:error, _reason} = error ->
              error

            result ->
              Sessions.register(table, fork, graph, cp, parent: tid)
              result
          end
        end)

      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:resume, tid}, {:ok, _result}, socket) do
    {:noreply, if(tid == socket.assigns.selected, do: load_timeline(socket), else: socket)}
  end

  def handle_async({:resume, _tid}, {:exit, reason}, socket) do
    {:noreply, put_flash(socket, :error, "resume 실패: #{inspect(reason)}")}
  end

  def handle_async({:branch, _fork}, {:ok, {:error, reason}}, socket) do
    {:noreply, put_flash(socket, :error, "분기 실패: #{inspect(reason)}")}
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

  defp load_sessions(socket) do
    sessions =
      socket.assigns.table
      |> Sessions.list()
      |> Enum.map(&Map.merge(&1, session_meta(&1)))

    assign(socket, :sessions, sessions)
  end

  # 목록에 상태/최신 step을 곁들인다 — 클릭 없이도 멈춤(interrupt)·완료(done)를 알 수 있게.
  defp session_meta(%{checkpointer: {mod, config}, thread_id: tid}) do
    case mod.get(config, tid, :latest) do
      {:ok, %{next: [], step: step}} ->
        %{status: :done, step: step}

      {:ok, %{interrupt_info: info, step: step}} when not is_nil(info) ->
        %{status: :interrupted, step: step}

      {:ok, %{step: step}} ->
        %{status: :running, step: step}

      :not_found ->
        %{status: :empty, step: nil}
    end
  end

  defp load_timeline(socket) do
    case Sessions.get(socket.assigns.table, socket.assigns.selected) do
      {:ok, %{checkpointer: cp}} ->
        assign(socket, :events, Timeline.build(cp, socket.assigns.selected))

      :error ->
        assign(socket, :events, [])
    end
  end

  defp kind_label(:start), do: "● start"
  defp kind_label(:step), do: "→ step"
  defp kind_label(:interrupt), do: "⏸ interrupt"
  defp kind_label(:done), do: "✓ done"

  defp status_label(:interrupted), do: "⏸ paused"
  defp status_label(:done), do: "✓ done"
  defp status_label(:running), do: "running"
  defp status_label(:empty), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <p class="subtitle">체크포인트 타임라인 · 승인/거절 · 여기서 분기</p>

    <div class="layout">
      <aside class="sessions">
        <h2>Threads</h2>
        <p :if={@sessions == []} class="empty">
          <span class="empty-icon">📭</span>등록된 실행이 없습니다.<br />
          <code>ElTrace.observe/4</code>로 thread를 등록하세요.
        </p>
        <button
          :for={s <- @sessions}
          class={["session", s.thread_id == @selected && "active"]}
          phx-click="select"
          phx-value-thread={s.thread_id}
        >
          <div class="tid-row">
            <span class={["status-dot", to_string(s.status)]} title={status_label(s.status)}></span>
            <span class="tid"><%= s.thread_id %></span>
          </div>
          <div class="meta">
            <span :if={s.step} class="step-badge">step <%= s.step %></span>
            <span class={["status-badge", to_string(s.status)]}><%= status_label(s.status) %></span>
            <span :if={s.parent} class="fork">⑂ from <%= s.parent %></span>
          </div>
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
            <%= if e[:payload] do %>
              <div class="payload-label">Payload</div>
              <pre class="payload"><%= inspect(e.payload, pretty: true) %></pre>
            <% end %>
            <div class="actions">
              <%= if e.kind == :interrupt do %>
                <button class="btn btn-approve" phx-click="approve" phx-disable-with="처리 중…">승인</button>
                <button class="btn btn-reject" phx-click="reject" phx-disable-with="처리 중…">거절</button>
              <% end %>
              <button
                class="btn btn-branch small"
                phx-click="branch"
                phx-value-step={e.step}
                phx-disable-with="분기 중…"
              >
                여기서 분기
              </button>
            </div>
          </div>
        <% else %>
          <p class="empty"><span class="empty-icon">👈</span>왼쪽에서 thread를 선택하세요.</p>
        <% end %>
      </section>
    </div>
    """
  end
end
