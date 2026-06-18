defmodule ElGraph.Signal.Dedup do
  @moduledoc """
  멱등 수신용 경계 있는(bounded) 중복 id 집합 (SPEC §6, at-least-once 안전).

  분산(`:pg`) 전달은 best-effort라 netsplit 회복 등에서 같은 시그널이 재전달될 수 있다.
  수신 측이 이 구조로 `Signal.id`를 추적하면 재전달을 안전하게 한 번만 처리한다.

  **순수 함수형**(별도 프로세스 없음)이라 어느 GenServer 상태에든 박아 쓴다.
  메모리는 `max`개로 제한되며, 초과 시 가장 오래된 id를 잊는다(경계 트레이드오프 —
  아주 오래 전 id는 다시 새로 보일 수 있다). `ElGraph.Agent`는 `dedup: max` 옵션으로 자동 사용.

      d = Dedup.new(1024)
      {:new, d}       = Dedup.put(d, signal.id)   # 처음 본 id
      {:duplicate, d} = Dedup.put(d, signal.id)   # 재전달 → 무시
  """

  defstruct seen: MapSet.new(), order: [], count: 0, max: 1024

  @type t :: %__MODULE__{
          seen: MapSet.t(),
          order: [term()],
          count: non_neg_integer(),
          max: pos_integer()
        }

  @doc "최대 `max`개 id를 기억하는 빈 dedup을 만든다."
  @spec new(pos_integer()) :: t()
  def new(max \\ 1024) when is_integer(max) and max > 0, do: %__MODULE__{max: max}

  @doc """
  id를 기록한다. 처음 보면 `{:new, dedup}`, 이미 봤으면 `{:duplicate, dedup}`.
  새 id 추가로 `max`를 넘으면 가장 오래된 id를 제거한다.
  """
  @spec put(t(), term()) :: {:new | :duplicate, t()}
  def put(%__MODULE__{seen: seen} = dedup, id) do
    if MapSet.member?(seen, id) do
      {:duplicate, dedup}
    else
      dedup = %{
        dedup
        | seen: MapSet.put(seen, id),
          order: [id | dedup.order],
          count: dedup.count + 1
      }

      {:new, evict(dedup)}
    end
  end

  defp evict(%__MODULE__{count: count, max: max} = dedup) when count <= max, do: dedup

  defp evict(%__MODULE__{order: order, seen: seen} = dedup) do
    {oldest, rest} = List.pop_at(order, -1)
    %{dedup | order: rest, seen: MapSet.delete(seen, oldest), count: dedup.count - 1}
  end
end
