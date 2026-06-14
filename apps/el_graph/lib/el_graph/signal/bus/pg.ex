defmodule ElGraph.Signal.Bus.Pg do
  @moduledoc """
  `:pg` 기반 분산 시그널 버스 transport (SPEC §6).

  버스 이름이 `:pg` scope가 된다. 구독은 패턴을 그룹키로 `:pg.join`하고, 발행은
  scope의 모든 그룹 중 시그널 타입에 매칭되는 것의 멤버에게 `send_signal`한다.
  `:pg`가 클러스터 전체 멤버십을 동기화하므로 발행은 원격 노드의 Agent에도 닿는다.

  함수 구독은 지원하지 않는다 (fun은 노드 경계를 넘지 못한다) — `ElGraph.Signal.Bus`가 거부.
  """

  alias ElGraph.Signal

  @doc false
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)

    result =
      case :pg.start_link(name) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end

    :persistent_term.put(key(name), true)
    result
  end

  @doc false
  def started?(name), do: :persistent_term.get(key(name), false)

  @doc false
  def join(scope, pattern) do
    :ok = :pg.join(scope, pattern, self())
  end

  @doc false
  def publish(scope, %Signal{type: type} = signal) do
    for pattern <- :pg.which_groups(scope), Signal.matches?(pattern, type) do
      for pid <- :pg.get_members(scope, pattern) do
        ElGraph.Agent.send_signal(pid, signal)
      end
    end

    :ok
  end

  @doc false
  def reset(name), do: :persistent_term.erase(key(name))

  defp key(name), do: {__MODULE__, name}
end
