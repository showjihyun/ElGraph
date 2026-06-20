defmodule ElGraph.Ctx.Internal do
  @moduledoc false
  # executor가 노드 호출에 싣는 실행 배선 — 노드가 직접 만질 필요 없는 내부 상태.
  # `ElGraph.Ctx`의 공개 인터페이스(thread_id/step/node/assigns + emit/interrupt/memo/cancelled?)
  # 뒤로 격리되며, 이 구조체는 자유롭게 진화할 수 있다(공개 @type을 건드리지 않음).

  defstruct event_sink: nil,
            resume_values: [],
            node_key: nil,
            interrupt_counter: nil,
            cancel_flag: nil,
            task_cache: nil,
            max_concurrency: nil

  @type t :: %__MODULE__{
          event_sink: pid() | nil,
          resume_values: [term()],
          node_key: atom() | {atom(), non_neg_integer()} | nil,
          interrupt_counter: :counters.counters_ref() | nil,
          cancel_flag: :atomics.atomics_ref() | nil,
          task_cache: :ets.tid() | nil,
          max_concurrency: pos_integer() | nil
        }
end

defmodule ElGraph.Ctx do
  @moduledoc """
  노드 실행 컨텍스트. 모든 노드는 `(state, ctx)` 2-인자로 호출된다 (SPEC §3.2).

  노드가 보는 인터페이스는 작다 — 필드 4개와 함수 4개:

    * 필드: `ctx.thread_id`, `ctx.step`, `ctx.node`, `ctx.assigns`
    * 함수: `emit/2`(스트리밍 이벤트), `interrupt/2`(동적 인터럽트, SPEC §3.6),
      `cancelled?/1`(협조적 취소 확인, SPEC §3.9), `memo/3`(replay-safe 메모이즈)

  `:assigns`는 호출 단위(per-invocation)의 읽기 전용 컨텍스트로,
  `invoke(graph, input, assigns: %{...})`로 주입되어 모든 노드의 `ctx.assigns`로 전달된다.

  실행기 내부 배선(이벤트 싱크, 취소 플래그, task 캐시, 인터럽트 카운터, fan-out 식별자 등)은
  `ctx.private`(`ElGraph.Ctx.Internal`, opaque)에 격리된다 — 노드가 만질 필요가 없다.
  """

  alias ElGraph.Ctx.Internal
  alias ElGraph.Event

  defstruct [:thread_id, :step, :node, assigns: %{}, private: nil]

  @type t :: %__MODULE__{
          thread_id: String.t(),
          step: non_neg_integer(),
          node: atom(),
          assigns: map(),
          private: Internal.t() | nil
        }

  # 실행기 밖에서 노드를 직접 호출하면 private가 없을 수 있다 — 빈 기본값으로 안전 처리한다.
  @doc false
  @spec internal(t()) :: Internal.t()
  def internal(%__MODULE__{private: nil}), do: %Internal{}
  def internal(%__MODULE__{private: %Internal{} = private}), do: private

  @doc """
  스트리밍 이벤트를 구독자에게 방출한다.

  `invoke/3`의 `:event_sink` 옵션으로 구독자 pid가 주어진 경우
  `{:el_graph_event, %{thread_id, step, node, event}}` 메시지를 보낸다. 없으면 no-op.
  """
  @spec emit(t(), term()) :: :ok
  def emit(%__MODULE__{} = ctx, event) do
    case internal(ctx).event_sink do
      nil ->
        :ok

      sink when is_pid(sink) ->
        send(sink, {:el_graph_event, Event.node(ctx.thread_id, ctx.step, ctx.node, event)})
        :ok
    end
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
    private = internal(ctx)
    count = next_interrupt_count(private.interrupt_counter)

    if count <= length(private.resume_values) do
      Enum.at(private.resume_values, count - 1)
    else
      throw({:__el_graph_interrupt__, payload})
    end
  end

  defp next_interrupt_count(nil), do: 1

  defp next_interrupt_count(counter) do
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
  task 캐시가 없는 컨텍스트(예: 실행기 밖에서 노드 직접 호출)에서는 그냥 `fun`을 실행한다.

  캐시는 노드 실행 인스턴스로 네임스페이스된다 — `:send` fan-out으로 같은 노드가 한 superstep에
  여러 번 돌 때도 인스턴스별 memo가 서로 덮어쓰지 않는다.

      answer = Ctx.memo(ctx, :classify, fn -> LLM.chat(...) end)
  """
  @spec memo(t(), term(), (-> value)) :: value when value: term()
  def memo(%__MODULE__{} = ctx, key, fun) do
    private = internal(ctx)

    case private.task_cache do
      nil ->
        fun.()

      tid ->
        cache_key = {private.node_key || ctx.node, key}

        case :ets.lookup(tid, cache_key) do
          [{_k, value}] ->
            value

          [] ->
            value = fun.()
            :ets.insert(tid, {cache_key, value})
            value
        end
    end
  end

  @doc """
  협조적 취소 확인 (SPEC §3.9). 긴 루프나 스트림 처리 중 주기적으로 호출하라.

  `ElGraph.Runner.cancel/2`가 플래그를 세우면 `true`가 된다. 노드가 이를 무시하면
  유예시간 후 brutal kill 된다.
  """
  @spec cancelled?(t()) :: boolean()
  def cancelled?(%__MODULE__{} = ctx) do
    case internal(ctx).cancel_flag do
      nil -> false
      flag -> :atomics.get(flag, 1) == 1
    end
  end
end
