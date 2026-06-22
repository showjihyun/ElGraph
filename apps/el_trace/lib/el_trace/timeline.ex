defmodule ElTrace.Timeline do
  @moduledoc """
  ElTrace #1·#2: thread의 체크포인트 체인을 생애 타임라인으로 (도그푸딩 세션 7).

  Langfuse가 못 하는 두 가지를 ElGraph의 체크포인트로 제공한다:
    * #1 인터럽트 가시성 — "왜 멈췄나"(노드 + payload)를 명시
    * #2 thread 생애 — invoke→interrupt→resume의 전체를 하나의 타임라인으로

  범용 trace(span/토큰)는 Langfuse에 위임하고, ElTrace는 체크포인트가 아는 인과만 다룬다.

      cp = {ElGraph.Checkpointer.ETS, config}
      ElTrace.Timeline.build(cp, "thread-1") |> ElTrace.Timeline.render() |> IO.puts()
  """

  @type event :: map()

  alias ElGraph.Checkpoint

  @doc "thread의 체크포인트들을 step 순서의 타임라인 이벤트로 변환한다."
  @spec build({module(), term()}, String.t()) :: [event()]
  def build({mod, config}, thread_id) do
    config
    |> then(&mod.list(&1, thread_id))
    |> Enum.flat_map(fn %{step: step} ->
      # list와 get 사이에 체크포인트가 사라질 수 있다(동시 pruning/완료) — 크래시 대신 건너뛴다.
      case mod.get(config, thread_id, step) do
        {:ok, checkpoint} -> [to_event(checkpoint)]
        :not_found -> []
      end
    end)
  end

  # 인터럽트 기록(interrupt_info)이 다른 분류보다 우선 — 재개 후에도 "여기서 멈췄다"를 보여준다.
  defp to_event(%Checkpoint{step: step, interrupt_info: %{node: node, payload: payload}}),
    do: %{step: step, kind: :interrupt, node: node, payload: payload}

  defp to_event(%Checkpoint{step: step, next: []}), do: %{step: step, kind: :done}
  defp to_event(%Checkpoint{step: 0, next: next}), do: %{step: 0, kind: :start, next: next}
  defp to_event(%Checkpoint{step: step, next: next}), do: %{step: step, kind: :step, next: next}

  @doc "타임라인 이벤트를 사람이 읽는 텍스트로 렌더링한다."
  @spec render([event()]) :: String.t()
  def render(events), do: Enum.map_join(events, "\n", &render_line/1)

  defp render_line(%{step: s, kind: :interrupt, node: n, payload: p}),
    do: "  step #{s}  ⏸ interrupt @#{n}  payload=#{inspect(p)}"

  defp render_line(%{step: s, kind: :done}), do: "  step #{s}  ✓ done"

  defp render_line(%{step: s, kind: :start, next: next}),
    do: "  step #{s}  ● start → #{inspect(next)}"

  defp render_line(%{step: s, kind: :step, next: next}), do: "  step #{s}  → #{inspect(next)}"
end
