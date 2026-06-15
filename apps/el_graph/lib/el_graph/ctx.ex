defmodule ElGraph.Ctx do
  @moduledoc """
  노드 실행 컨텍스트. 모든 노드는 `(state, ctx)` 2-인자로 호출된다 (SPEC §3.2).

  스트리밍 이벤트 방출, 협조적 취소 확인, 실행 메타데이터 접근의 통로다.
  동적 인터럽트(`interrupt/2`)는 체크포인터와 함께 도입된다.

  `:assigns`는 호출 단위(per-invocation)의 읽기 전용 컨텍스트로,
  `invoke(graph, input, assigns: %{...})`로 주입되어 모든 노드의 `ctx.assigns`로 전달된다.
  """

  defstruct [
    :thread_id,
    :step,
    :node,
    :event_sink,
    resume_values: [],
    interrupt_counter: nil,
    cancel_flag: nil,
    assigns: %{}
  ]

  @type t :: %__MODULE__{
          thread_id: String.t(),
          step: non_neg_integer(),
          node: atom(),
          event_sink: pid() | nil,
          resume_values: [term()],
          interrupt_counter: :counters.counters_ref() | nil,
          cancel_flag: :atomics.atomics_ref() | nil,
          assigns: map()
        }

  @doc """
  스트리밍 이벤트를 구독자에게 방출한다.

  `invoke/3`의 `:event_sink` 옵션으로 구독자 pid가 주어진 경우
  `{:el_graph_event, %{thread_id, step, node, event}}` 메시지를 보낸다. 없으면 no-op.
  """
  @spec emit(t(), term()) :: :ok
  def emit(%__MODULE__{event_sink: nil}, _event), do: :ok

  def emit(%__MODULE__{event_sink: sink} = ctx, event) when is_pid(sink) do
    send(
      sink,
      {:el_graph_event, %{thread_id: ctx.thread_id, step: ctx.step, node: ctx.node, event: event}}
    )

    :ok
  end

  @doc """
  동적 인터럽트 (SPEC §3.6). 실행을 중단하고 호출자에게 `payload`와 함께
  `{:interrupted, info}`를 반환하게 한다.

  `ElGraph.resume(graph, resume: value)`로 재개하면 노드가 **처음부터 재실행**되고,
  이 함수는 이번에는 주입된 `value`를 반환한다. 한 노드 안의 여러 interrupt 호출은
  호출 순서로 값과 매칭되므로 호출 순서는 결정적이어야 한다.
  interrupt 이전의 부수효과는 재실행 시 중복된다 — interrupt는 노드 초반에 두라.
  """
  @spec interrupt(t(), term()) :: term()
  def interrupt(%__MODULE__{} = ctx, payload) do
    count = next_interrupt_count(ctx)

    if count <= length(ctx.resume_values) do
      Enum.at(ctx.resume_values, count - 1)
    else
      throw({:__el_graph_interrupt__, payload})
    end
  end

  defp next_interrupt_count(%__MODULE__{interrupt_counter: nil}), do: 1

  defp next_interrupt_count(%__MODULE__{interrupt_counter: counter}) do
    :ok = :counters.add(counter, 1, 1)
    :counters.get(counter, 1)
  end

  @doc """
  협조적 취소 확인 (SPEC §3.9). 긴 루프나 스트림 처리 중 주기적으로 호출하라.

  `ElGraph.Runner.cancel/2`가 플래그를 세우면 `true`가 된다. 노드가 이를 무시하면
  유예시간 후 brutal kill 된다.
  """
  @spec cancelled?(t()) :: boolean()
  def cancelled?(%__MODULE__{cancel_flag: nil}), do: false
  def cancelled?(%__MODULE__{cancel_flag: flag}), do: :atomics.get(flag, 1) == 1
end
