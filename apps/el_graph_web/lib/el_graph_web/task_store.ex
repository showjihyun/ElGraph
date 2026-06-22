defmodule ElGraphWeb.TaskStore do
  @moduledoc """
  A2A Task의 인메모리 저장소 (task_id → Task 맵).

  ETS 테이블을 소유하는 작은 GenServer다. 읽기(`get/2`)는 ETS에서 직접 하므로
  동시성에 안전하고, 쓰기(`put/2`)는 GenServer를 거친다. 호스트가
  `ElGraphWeb.server_spec/1`을 통해, 테스트가 `start_supervised!/1`로 마운트한다.

  `ref`는 시작 시 부여된 pid 또는 등록 이름이다 — 라우터에 `conn.assigns[:task_store]`로
  주입한다(에이전트 레지스트리와 동일한 방식).
  """

  use GenServer

  @type ref :: GenServer.server()
  @type owner :: term()

  @default_max 10_000

  @doc """
  Task를 저장한다. id 필드를 키로 쓰고, `owner`로 호출자에 스코프한다(기본 `nil`).
  보관 수가 `:max`(기본 #{@default_max})를 넘으면 가장 오래된 Task부터 축출한다.
  """
  @spec put(ref(), map(), owner()) :: :ok
  def put(server, %{"id" => _} = task, owner \\ nil),
    do: GenServer.call(server, {:put, owner, task})

  @doc "task_id로 Task를 조회한다 — `owner`가 저장 시 owner와 일치할 때만 반환한다."
  @spec get(ref(), String.t(), owner()) :: {:ok, map()} | :error
  def get(server, id, owner \\ nil) do
    case :ets.lookup(table(server), id) do
      [{^id, ^owner, task}] -> {:ok, task}
      _ -> :error
    end
  end

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
    {:ok, %{table: table, max: Keyword.get(opts, :max, @default_max), order: :queue.new()}}
  end

  @impl true
  def handle_call({:put, owner, %{"id" => id} = task}, _from, state) do
    new? = not :ets.member(state.table, id)
    :ets.insert(state.table, {id, owner, task})
    order = if new?, do: :queue.in(id, state.order), else: state.order
    {:reply, :ok, evict_over_cap(%{state | order: order})}
  end

  @impl true
  def handle_call(:table, _from, state), do: {:reply, state.table, state}

  # 보관 수가 상한을 넘으면 가장 오래 전에 넣은 id부터 ETS에서 지운다(메모리 무한 증가 차단).
  defp evict_over_cap(%{order: order, max: max, table: table} = state) do
    if :queue.len(order) > max do
      {{:value, oldest}, order} = :queue.out(order)
      :ets.delete(table, oldest)
      evict_over_cap(%{state | order: order})
    else
      state
    end
  end

  defp table(server), do: GenServer.call(server, :table)
end
