defmodule ElTrace.Telemetry do
  @moduledoc """
  el_graph의 실행 텔레메트리를 thread별 `Phoenix.PubSub` 토픽으로 중계한다.

  LiveView는 `thread_topic(thread_id)`를 구독하고, 이벤트가 오면 체크포인트에서
  타임라인을 다시 만들어 새로고침 없이 갱신한다. ElTrace는 인과(노드 진행·인터럽트·완료)만
  중계하고 span/토큰 같은 범용 trace는 Langfuse에 위임한다.

  중계 이벤트:
    * `[:el_graph, :node, :stop]`      → `:node_stop` (superstep 진행)
    * `[:el_graph, :node, :interrupt]` → `:interrupt` (사람 대기 — 승인/거절 버튼 노출)
    * `[:el_graph, :invoke, :stop]`    → `:invoke_stop` (실행 완료)
  """

  @handler_id "el-trace-telemetry"

  @events [
    [:el_graph, :node, :stop],
    [:el_graph, :node, :interrupt],
    [:el_graph, :invoke, :stop]
  ]

  @doc "el_graph 텔레메트리에 핸들러를 붙인다 (재호출 안전 — 기존 핸들러를 먼저 뗀다)."
  @spec attach() :: :ok
  def attach do
    detach()
    _ = :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, %{})
    :ok
  end

  @doc "핸들러를 뗀다."
  @spec detach() :: :ok
  def detach do
    :telemetry.detach(@handler_id)
    :ok
  end

  @doc "thread의 실시간 이벤트 PubSub 토픽."
  @spec thread_topic(String.t()) :: String.t()
  def thread_topic(thread_id), do: "thread:" <> thread_id

  @doc false
  def handle_event([:el_graph, :node, :stop], _measurements, %{thread_id: tid} = meta, _config),
    do: broadcast(tid, :node_stop, meta)

  def handle_event(
        [:el_graph, :node, :interrupt],
        _measurements,
        %{thread_id: tid} = meta,
        _config
      ),
      do: broadcast(tid, :interrupt, meta)

  def handle_event([:el_graph, :invoke, :stop], _measurements, %{thread_id: tid} = meta, _config),
    do: broadcast(tid, :invoke_stop, meta)

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  defp broadcast(thread_id, kind, meta) do
    event = %{
      thread_id: thread_id,
      kind: kind,
      node: Map.get(meta, :node),
      step: Map.get(meta, :step)
    }

    Phoenix.PubSub.broadcast(ElTrace.PubSub, thread_topic(thread_id), {:thread_event, event})
  end
end
