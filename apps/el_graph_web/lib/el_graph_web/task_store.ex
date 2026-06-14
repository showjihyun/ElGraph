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

  @doc "Task를 저장한다. id 필드를 키로 쓴다."
  @spec put(ref(), map()) :: :ok
  def put(server, %{"id" => _} = task), do: GenServer.call(server, {:put, task})

  @doc "task_id로 Task를 조회한다."
  @spec get(ref(), String.t()) :: {:ok, map()} | :error
  def get(server, id) do
    case :ets.lookup(table(server), id) do
      [{^id, task}] -> {:ok, task}
      [] -> :error
    end
  end

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    {:ok, :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])}
  end

  @impl true
  def handle_call({:put, %{"id" => id} = task}, _from, table) do
    :ets.insert(table, {id, task})
    {:reply, :ok, table}
  end

  @impl true
  def handle_call(:table, _from, table), do: {:reply, table, table}

  defp table(server), do: GenServer.call(server, :table)
end
