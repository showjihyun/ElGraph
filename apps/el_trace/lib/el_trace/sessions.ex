defmodule ElTrace.Sessions do
  @moduledoc """
  ElTrace 제어 평면 레지스트리: `thread_id => {graph, checkpointer, parent}`.

  타임라인 UI가 resume(승인/거절)·분기(Replay)를 수행하려면 컴파일된 `%ElGraph.Graph{}`와
  체크포인터 핸들이 필요하지만, 체크포인트에는 그래프 정의가 없다. 그래서 실행을 시작할 때
  여기에 등록해 두고 LiveView가 조회한다.

  `Checkpointer.ETS`와 동일하게 인스턴스별 테이블 소유자 — named 싱글턴이 아니므로
  `async: true` 테스트와 호환된다. 앱은 `name: ElTrace.Sessions`로 하나를 띄운다.
  """

  use GenServer

  @type session :: %{
          thread_id: String.t(),
          graph: ElGraph.Graph.t(),
          checkpointer: {module(), term()},
          parent: String.t() | nil
        }

  @sessions_topic "sessions"

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "이 인스턴스의 ETS 테이블 핸들을 반환한다 (조회/등록의 인자)."
  @spec table(GenServer.server()) :: :ets.tid()
  def table(server), do: GenServer.call(server, :table)

  @doc "LiveView가 세션 목록 변경을 받기 위해 구독하는 PubSub 토픽."
  def sessions_topic, do: @sessions_topic

  @doc "실행 세션을 등록한다. `:parent`로 분기(fork)의 부모 thread를 기록한다."
  @spec register(:ets.tid(), String.t(), ElGraph.Graph.t(), {module(), term()}, keyword()) :: :ok
  def register(table, thread_id, graph, checkpointer, opts \\ []) do
    session = %{
      thread_id: thread_id,
      graph: graph,
      checkpointer: checkpointer,
      parent: Keyword.get(opts, :parent)
    }

    true = :ets.insert(table, {thread_id, session})
    Phoenix.PubSub.broadcast(ElTrace.PubSub, @sessions_topic, :sessions_changed)
    :ok
  end

  @doc "thread의 세션을 조회한다."
  @spec get(:ets.tid(), String.t()) :: {:ok, session()} | :error
  def get(table, thread_id) do
    case :ets.lookup(table, thread_id) do
      [{^thread_id, session}] -> {:ok, session}
      [] -> :error
    end
  end

  @doc "등록된 모든 세션 목록 (thread_id 오름차순)."
  @spec list(:ets.tid()) :: [session()]
  def list(table) do
    table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, session} -> session end)
    |> Enum.sort_by(& &1.thread_id)
  end

  @impl GenServer
  def init(_opts) do
    table = :ets.new(:el_trace_sessions, [:set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call(:table, _from, %{table: table} = state), do: {:reply, table, state}
end
