defmodule ElGraph.Checkpoint do
  @moduledoc """
  체크포인트 스냅샷 (SPEC §3.5).

  처음부터 동결되는 두 가지: `version` 필드(스키마 마이그레이션의 기반)와
  pending writes(어댑터에 별도 저장 — `c:ElGraph.Checkpointer.put_writes/4`).
  그래프 정의는 저장하지 않는다 — 재개 시 그래프는 항상 코드에서 재구성된다.

  `step`은 "다음에 실행할 superstep"을 뜻한다. `next: []`는 실행 완료를 뜻한다.
  `interrupted`는 동적 인터럽트를 일으킨 노드(재개 시 `nil`로 처리됨), `interrupts`는
  노드별 재개 주입 값(`ElGraph.resume`의 `:resume`)이다. `interrupt_info`는 인터럽트
  발생 기록(`%{node, payload}`)으로 재개 후에도 보존된다 — ElTrace가 "왜 멈췄나"를 보여주는 근거.
  """

  defstruct version: 1,
            thread_id: nil,
            step: 0,
            state: %{},
            next: [],
            interrupted: nil,
            interrupts: %{},
            interrupt_info: nil,
            task_cache: %{},
            created_at: nil

  @type t :: %__MODULE__{
          version: pos_integer(),
          thread_id: String.t(),
          step: non_neg_integer(),
          state: map(),
          # 저장 형태는 엔트리 튜플 {key, node, input}; resume은 노드 atom도 받는다(back-compat).
          next: [atom() | {term(), atom(), term()}],
          interrupted: atom() | nil,
          interrupts: %{atom() => [term()]},
          interrupt_info: %{node: atom(), payload: term()} | nil,
          task_cache: %{{atom(), term()} => term()},
          created_at: integer() | nil
        }

  @doc """
  상태가 영속화 가능한지 깊이 검사한다 (SPEC §3.8).

  pid/reference/port/로컬 익명 함수는 재시작 후 재개 시 깨지므로 명시적 에러.
  원격 캡처(`&Mod.fun/2`)는 허용한다.
  """
  @spec validate_serializable(term()) :: :ok | {:error, {:not_serializable, term()}}
  def validate_serializable(term), do: check(term)

  defp check(term) when is_pid(term) or is_reference(term) or is_port(term),
    do: {:error, {:not_serializable, term}}

  defp check(fun) when is_function(fun) do
    case Function.info(fun, :type) do
      {:type, :external} -> :ok
      _local -> {:error, {:not_serializable, fun}}
    end
  end

  defp check(list) when is_list(list), do: check_all(list)
  defp check(tuple) when is_tuple(tuple), do: check_all(Tuple.to_list(tuple))
  defp check(%_struct{} = struct), do: struct |> Map.from_struct() |> Map.to_list() |> check_all()
  defp check(map) when is_map(map), do: check_all(Map.to_list(map))
  defp check(_other), do: :ok

  defp check_all(items) do
    Enum.find_value(items, :ok, fn item ->
      case check(item) do
        :ok -> nil
        error -> error
      end
    end)
  end
end
