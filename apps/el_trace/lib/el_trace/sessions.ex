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

  # 세션 레지스트리 상한 — 장기 실행 호스트가 많은 thread를 관찰해도 무한 증가(메모리 누수)하지
  # 않도록 가장 오래된 세션부터 축출한다. 세션마다 그래프 구조체를 보관하므로 더 중요하다.
  @default_max 1_000

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
      parent: Keyword.get(opts, :parent),
      # 단조 증가 유니크 정수 — 축출 순서(가장 오래된 것 = 최소 seq)용. 별도 카운터 행이 없어
      # 테스트가 :ets.delete_all_objects로 테이블을 비워도 깨지지 않는다.
      seq: System.unique_integer([:monotonic])
    }

    true = :ets.insert(table, {thread_id, session})
    enforce_cap(table)
    Phoenix.PubSub.broadcast(ElTrace.PubSub, @sessions_topic, :sessions_changed)
    :ok
  end

  @doc "thread의 세션을 조회한다."
  @spec get(:ets.tid(), String.t()) :: {:ok, session()} | :error
  def get(table, thread_id) do
    case :ets.lookup(table, thread_id) do
      [{^thread_id, session}] -> {:ok, Map.delete(session, :seq)}
      [] -> :error
    end
  end

  @doc "등록된 모든 세션 목록 (thread_id 오름차순)."
  @spec list(:ets.tid()) :: [session()]
  def list(table) do
    table
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {{:__meta__, _key}, _value} -> []
      {_id, session} -> [Map.delete(session, :seq)]
    end)
    |> Enum.sort_by(& &1.thread_id)
  end

  @impl GenServer
  def init(opts) do
    table = :ets.new(:el_trace_sessions, [:set, :public, read_concurrency: true])

    # 상한만 메타행으로 둔다(축출은 세션의 seq로). 읽기는 메타행(튜플 키)을 걸러낸다.
    :ets.insert(table, {{:__meta__, :max}, Keyword.get(opts, :max, @default_max)})
    {:ok, %{table: table}}
  end

  # 실제 세션 수가 상한을 넘으면 가장 오래된(최소 seq) 세션을 지운다.
  defp enforce_cap(table) do
    if session_count(table) > max(table) do
      case oldest_session(table) do
        nil -> :ok
        id -> :ets.delete(table, id)
      end
    end

    :ok
  end

  # 세션 키는 thread_id(binary), 메타행 키는 {:__meta__, _}(tuple) — binary 키만 센다.
  defp session_count(table),
    do: :ets.select_count(table, [{{:"$1", :_}, [{:is_binary, :"$1"}], [true]}])

  defp max(table) do
    case :ets.lookup(table, {:__meta__, :max}) do
      [{_key, m}] -> m
      [] -> @default_max
    end
  end

  defp oldest_session(table) do
    folded =
      :ets.foldl(
        fn
          {id, %{seq: seq}}, nil when is_binary(id) -> {seq, id}
          {id, %{seq: seq}}, {min, _min_id} when is_binary(id) and seq < min -> {seq, id}
          _row, acc -> acc
        end,
        nil,
        table
      )

    case folded do
      {_seq, id} -> id
      nil -> nil
    end
  end

  @impl GenServer
  def handle_call(:table, _from, %{table: table} = state), do: {:reply, table, state}
end
