defmodule ElGraph.RateLimiter do
  @moduledoc """
  프로바이더별 동시 실행 제한 세마포어 (SPEC §5).

  에이전트 50개가 같은 LLM API를 동시에 때리는 상황의 필수 장치.
  보유자(holder)를 모니터링해 프로세스가 죽으면 슬롯을 자동 회수한다 — 누수 없음.
  프로세스당 슬롯 1개 (재진입 불가).

      children = [{ElGraph.RateLimiter, limit: 5, name: MyApp.OpenAILimiter}]
      ElGraph.RateLimiter.with_limit(MyApp.OpenAILimiter, fn -> OpenAI.chat(...) end)
  """

  use GenServer

  def start_link(opts) do
    limit = Keyword.fetch!(opts, :limit)
    GenServer.start_link(__MODULE__, limit, Keyword.take(opts, [:name]))
  end

  @doc "슬롯을 획득한다. 빈 슬롯이 없으면 대기한다."
  @spec acquire(GenServer.server(), timeout()) :: :ok
  def acquire(server, timeout \\ 5_000) do
    GenServer.call(server, :acquire, timeout)
  end

  @doc "슬롯을 반환한다."
  @spec release(GenServer.server()) :: :ok
  def release(server) do
    GenServer.cast(server, {:release, self()})
  end

  @doc "슬롯 안에서 함수를 실행한다. 예외가 나도 슬롯은 반환된다."
  @spec with_limit(GenServer.server(), (-> result)) :: result when result: term()
  def with_limit(server, fun) do
    :ok = acquire(server)

    try do
      fun.()
    after
      release(server)
    end
  end

  @impl GenServer
  def init(limit) do
    {:ok, %{limit: limit, holders: %{}, waiting: :queue.new()}}
  end

  @impl GenServer
  def handle_call(:acquire, {pid, _tag} = from, state) do
    if map_size(state.holders) < state.limit do
      {:reply, :ok, grant(state, pid)}
    else
      {:noreply, %{state | waiting: :queue.in({from, pid}, state.waiting)}}
    end
  end

  @impl GenServer
  def handle_cast({:release, pid}, state), do: {:noreply, release_holder(state, pid)}

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # 보유자가 죽으면 슬롯 자동 회수 — 누수 방지의 핵심.
    {:noreply, release_holder(state, pid)}
  end

  defp grant(state, pid) do
    ref = Process.monitor(pid)
    %{state | holders: Map.put(state.holders, pid, ref)}
  end

  defp release_holder(state, pid) do
    case Map.pop(state.holders, pid) do
      {nil, _holders} ->
        state

      {ref, holders} ->
        Process.demonitor(ref, [:flush])
        grant_next(%{state | holders: holders})
    end
  end

  defp grant_next(state) do
    case :queue.out(state.waiting) do
      {{:value, {from, pid}}, waiting} ->
        GenServer.reply(from, :ok)
        grant(%{state | waiting: waiting}, pid)

      {:empty, _waiting} ->
        state
    end
  end
end
