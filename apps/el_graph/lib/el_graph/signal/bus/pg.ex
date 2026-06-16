defmodule ElGraph.Signal.Bus.Pg do
  @moduledoc """
  `:pg` 기반 분산 시그널 버스 transport (SPEC §6).

  버스 이름이 `:pg` scope가 된다. 구독은 패턴을 그룹키로 `:pg.join`하고, 발행은
  scope의 모든 그룹 중 시그널 타입에 매칭되는 것의 멤버에게 `send_signal`한다.
  `:pg`가 클러스터 전체 멤버십을 동기화하므로 발행은 원격 노드의 Agent에도 닿는다.

  함수 구독은 지원하지 않는다 (fun은 노드 경계를 넘지 못한다) — `ElGraph.Signal.Bus`가 거부.

  ## 분산 운영 (SPEC §6)

    * **클러스터 형성** — ElGraph는 코어 의존성 0 원칙상 클러스터러를 번들하지 않는다.
      호스트 앱이 [libcluster](https://hex.pm/packages/libcluster)로 노드를 잇는다(예: `Cluster.Strategy.Gossip`).
      노드가 연결되면 `:pg`가 같은 scope의 멤버십을 자동 동기화한다.
    * **전달 보장** — `:pg` 발행은 **best-effort**다. netsplit 회복 시 멤버십 재동기화로 같은
      시그널이 **재전달**될 수 있다. `ElGraph.Signal`은 발행 시 `id`가 스탬프되므로, 수신 측은
      `ElGraph.Signal.Dedup`(또는 `ElGraph.Agent`의 `dedup: max` 옵션)으로 **at-least-once를
      멱등하게** 처리한다 — 재전달은 한 번만 실행된다.
    * **netsplit** — 분단 중에는 각 파티션이 자기 멤버에게만 닿는다(전달 손실 가능 — best-effort).
      회복 후 `:pg`가 멤버십을 재조정하며, 중복 전달은 위 멱등 수신으로 흡수된다.

  멀티노드 fan-out 검증: `test/el_graph/signal/bus_multinode_test.exs`(`:distributed`, `:peer` 2노드).
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
