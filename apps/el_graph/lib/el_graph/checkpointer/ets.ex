defmodule ElGraph.Checkpointer.ETS do
  @moduledoc """
  ETS 기반 기본 체크포인터 (SPEC §3.5).

  인스턴스별 테이블 — named table 싱글턴이 아니므로 `async: true` 테스트와 호환된다.
  이 GenServer는 테이블 소유(수명 관리)만 담당하고, 읽기/쓰기는 public 테이블에
  직접 수행한다 — 단일 프로세스로 직렬화하지 않는다 (otp-thinking ETS 패턴).

  호스트 앱 슈퍼비전 트리에 마운트:

      children = [ElGraph.Checkpointer.ETS]
      config = ElGraph.Checkpointer.ETS.config(pid)
      ElGraph.invoke(graph, input, checkpointer: {ElGraph.Checkpointer.ETS, config})
  """

  @behaviour ElGraph.Checkpointer

  use GenServer

  alias ElGraph.Checkpoint

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "이 인스턴스의 체크포인터 config(테이블 핸들)를 반환한다."
  @spec config(GenServer.server()) :: map()
  def config(server), do: GenServer.call(server, :config)

  @impl GenServer
  def init(opts) do
    table_opts = [:public, read_concurrency: true, write_concurrency: true]

    tables = %{
      checkpoints: :ets.new(:el_graph_checkpoints, [:ordered_set | table_opts]),
      writes: :ets.new(:el_graph_writes, [:set | table_opts]),
      keep: Keyword.get(opts, :keep, :all)
    }

    {:ok, tables}
  end

  @impl GenServer
  def handle_call(:config, _from, tables), do: {:reply, tables, tables}

  @impl ElGraph.Checkpointer
  def put(%{checkpoints: table} = config, %Checkpoint{} = checkpoint) do
    with :ok <- Checkpoint.validate_serializable(checkpoint) do
      true = :ets.insert(table, {{checkpoint.thread_id, checkpoint.step}, checkpoint})
      prune(config, checkpoint.thread_id)
      :ok
    end
  end

  # 보존 정책 (SPEC §3.5): {:last, n}이면 오래된 체크포인트와 해당 step의
  # pending writes를 정리해 긴 thread의 저장소 비대화를 막는다.
  defp prune(%{keep: :all}, _thread_id), do: :ok

  defp prune(%{checkpoints: table, writes: writes, keep: {:last, n}}, thread_id) do
    steps =
      table
      |> :ets.match({{thread_id, :"$1"}, :_})
      |> List.flatten()
      |> Enum.sort()

    for step <- Enum.drop(steps, -n) do
      :ets.delete(table, {thread_id, step})
      :ets.delete(writes, {thread_id, step})
    end

    :ok
  end

  @impl ElGraph.Checkpointer
  def get(%{checkpoints: table}, thread_id, :latest) do
    # :infinity(atom)는 모든 정수 step보다 크므로 prev가 해당 thread의 최고 step을 준다.
    case :ets.prev(table, {thread_id, :infinity}) do
      {^thread_id, _step} = key ->
        # 동시 prune이 prev와 lookup 사이에 이 키를 지웠을 수 있다 — 크래시(MatchError) 대신 :not_found.
        case :ets.lookup(table, key) do
          [{^key, checkpoint}] -> {:ok, checkpoint}
          [] -> :not_found
        end

      _other_thread_or_end ->
        :not_found
    end
  end

  def get(%{checkpoints: table}, thread_id, step) when is_integer(step) do
    case :ets.lookup(table, {thread_id, step}) do
      [{_key, checkpoint}] -> {:ok, checkpoint}
      [] -> :not_found
    end
  end

  @impl ElGraph.Checkpointer
  def put_writes(%{writes: table}, thread_id, step, writes) do
    with :ok <- Checkpoint.validate_serializable(writes) do
      true = :ets.insert(table, {{thread_id, step}, writes})
      :ok
    end
  end

  @impl ElGraph.Checkpointer
  def get_writes(%{writes: table}, thread_id, step) do
    case :ets.lookup(table, {thread_id, step}) do
      [{_key, writes}] -> writes
      [] -> []
    end
  end

  @impl ElGraph.Checkpointer
  def list(%{checkpoints: table}, thread_id) do
    # ordered_set의 match_object는 키 순서를 보존하므로 step 오름차순이 보장된다.
    table
    |> :ets.match_object({{thread_id, :_}, :_})
    |> Enum.map(fn {{_thread, step}, checkpoint} ->
      %{step: step, version: checkpoint.version}
    end)
  end
end
