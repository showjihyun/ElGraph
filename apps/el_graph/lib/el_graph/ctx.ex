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
    node_key: nil,
    resume_values: [],
    interrupt_counter: nil,
    cancel_flag: nil,
    assigns: %{},
    task_cache: nil,
    max_concurrency: nil
  ]

  @typedoc """
  노드 실행 인스턴스의 안정적 식별자. 일반 노드는 노드 이름(atom)과 같지만,
  `:send` fan-out으로 같은 노드가 한 superstep에 여러 번 등장할 때는 인스턴스마다
  다르다. 재개(replay) 시에도 동일하게 복원되므로 `memo/3` 캐시의 네임스페이스로 쓰인다.
  """
  @type node_key :: atom() | {atom(), non_neg_integer()}

  @type t :: %__MODULE__{
          thread_id: String.t(),
          step: non_neg_integer(),
          node: atom(),
          node_key: node_key() | nil,
          event_sink: pid() | nil,
          resume_values: [term()],
          interrupt_counter: :counters.counters_ref() | nil,
          cancel_flag: :atomics.atomics_ref() | nil,
          assigns: map(),
          task_cache: :ets.tid() | nil,
          max_concurrency: pos_integer() | nil
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
  부수효과 있는 계산(LLM/툴 호출 등)을 `key`로 메모이즈한다 (replay-safe durability).

  처음 호출되면 `fun`을 실행해 결과를 이 실행(run)의 task 캐시에 기록하고 반환한다.
  이후 같은 노드에서 같은 `key`로 다시 호출하거나(재시도), 인터럽트/크래시 후 **재개 시
  노드가 처음부터 재실행될 때**는 `fun`을 다시 돌리지 않고 캐시된 값을 돌려준다 —
  LLM 호출 중복 비용·중복 부수효과를 막는다(Temporal Activity / LangGraph `@task`에 해당).

  캐시는 체크포인트에 함께 영속되므로 재개(`resume`/`resume_from`)를 넘어 유효하다.
  따라서 `fun`의 결과는 직렬화 가능해야 한다(pid/ref/port 금지 — 재개 시 무의미).
  `task_cache`가 없는 컨텍스트(예: 실행기 밖에서 노드 직접 호출)에서는 그냥 `fun`을 실행한다.

  캐시는 `node_key`(노드 실행 인스턴스)로 네임스페이스된다 — `:send` fan-out으로 같은
  노드가 한 superstep에 여러 번 돌 때도 인스턴스별 memo가 서로 덮어쓰지 않는다.

      answer = Ctx.memo(ctx, :classify, fn -> LLM.chat(...) end)
  """
  @spec memo(t(), term(), (-> value)) :: value when value: term()
  def memo(%__MODULE__{task_cache: nil}, _key, fun), do: fun.()

  def memo(%__MODULE__{task_cache: tid} = ctx, key, fun) do
    cache_key = {ctx.node_key || ctx.node, key}

    case :ets.lookup(tid, cache_key) do
      [{_k, value}] ->
        value

      [] ->
        value = fun.()
        :ets.insert(tid, {cache_key, value})
        value
    end
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
