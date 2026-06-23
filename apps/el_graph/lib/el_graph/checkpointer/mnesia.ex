defmodule ElGraph.Checkpointer.Mnesia do
  @moduledoc """
  Mnesia 기반 내구 체크포인터 — BEAM 내장 분산 DB. **외부 인프라 0**.

  DETS가 단일 파일·단일 노드인 것과 달리, Mnesia는 `disc_copies`로 디스크 영속 + 멀티노드
  복제(분산 재개)까지 BEAM 런타임만으로 제공한다. ElGraph의 분산 스토리(`:pg`, libcluster)와
  자연스럽게 맞물린다.

      # (호스트 앱 부팅 전 1회 — disc 스키마 준비, node-global)
      ElGraph.Checkpointer.Mnesia.setup_disc!()

      children = [{ElGraph.Checkpointer.Mnesia, copies: :disc_copies}]
      cp = {ElGraph.Checkpointer.Mnesia, ElGraph.Checkpointer.Mnesia.config(pid)}

  테이블은 `ordered_set`(키 = `{:cp|:wr, thread_id, step}`) — step 정렬/`:latest`가 키 순서로 나온다.
  쓰기는 dirty 연산(단일 레코드라 원자적이고 빠름) — disc_copies면 디스크에 영속된다.
  `keep: {:last, n}`으로 오래된 체크포인트를 정리한다.
  """

  @behaviour ElGraph.Checkpointer

  use GenServer

  alias ElGraph.Checkpoint

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "이 인스턴스의 config(테이블명 + 보존정책)를 반환한다."
  @spec config(GenServer.server()) :: map()
  def config(server), do: GenServer.call(server, :config)

  @doc """
  disc_copies용 디스크 스키마를 (재)설정한다 — 호스트 앱이 부팅 전 1회 호출(node-global).
  Mnesia 디렉터리는 `config :mnesia, :dir` 또는 기본값을 따른다.
  """
  @spec setup_disc!([node()]) :: :ok
  def setup_disc!(nodes \\ [node()]) do
    :mnesia.stop()
    _ = :mnesia.create_schema(nodes)
    :ok = :mnesia.start()
    :ok
  end

  @impl GenServer
  def init(opts) do
    table = Keyword.get(opts, :table, :el_graph_mnesia)
    copies = Keyword.get(opts, :copies, :disc_copies)
    :ok = :mnesia.start()
    :ok = ensure_table(table, copies)
    {:ok, %{table: table, keep: Keyword.get(opts, :keep, :all)}}
  end

  @impl GenServer
  def handle_call(:config, _from, state), do: {:reply, Map.take(state, [:table, :keep]), state}

  defp ensure_table(table, copies) do
    opts = [{:type, :ordered_set}, {:attributes, [:key, :value]}, {copies, [node()]}]

    case :mnesia.create_table(table, opts) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, ^table}} -> :ok
    end

    :ok = :mnesia.wait_for_tables([table], 5_000)
  end

  @impl ElGraph.Checkpointer
  def put(%{table: table} = config, %Checkpoint{} = checkpoint) do
    with :ok <- Checkpoint.validate_serializable(checkpoint) do
      :ok = :mnesia.dirty_write({table, {:cp, checkpoint.thread_id, checkpoint.step}, checkpoint})
      prune(config, checkpoint.thread_id)
      :ok
    end
  end

  @impl ElGraph.Checkpointer
  def get(%{table: table}, thread_id, :latest) do
    case cp_steps(table, thread_id) do
      [] -> :not_found
      steps -> fetch(table, thread_id, Enum.max(steps))
    end
  end

  def get(%{table: table}, thread_id, step) when is_integer(step) do
    case :mnesia.dirty_read(table, {:cp, thread_id, step}) do
      [{_table, _key, checkpoint}] -> {:ok, checkpoint}
      [] -> :not_found
    end
  end

  @impl ElGraph.Checkpointer
  def put_writes(%{table: table}, thread_id, step, writes) do
    with :ok <- Checkpoint.validate_serializable(writes) do
      :ok = :mnesia.dirty_write({table, {:wr, thread_id, step}, writes})
      :ok
    end
  end

  @impl ElGraph.Checkpointer
  def get_writes(%{table: table}, thread_id, step) do
    case :mnesia.dirty_read(table, {:wr, thread_id, step}) do
      [{_table, _key, writes}] -> writes
      [] -> []
    end
  end

  @impl ElGraph.Checkpointer
  def list(%{table: table}, thread_id) do
    table
    |> cp_steps(thread_id)
    |> Enum.sort()
    # 동시 prune이 cp_steps 조회 후 지운 step은 건너뛴다(크래시 방지).
    |> Enum.flat_map(fn step ->
      case fetch(table, thread_id, step) do
        {:ok, cp} -> [%{step: step, version: cp.version}]
        :not_found -> []
      end
    end)
  end

  defp cp_steps(table, thread_id) do
    table
    |> :mnesia.dirty_match_object({table, {:cp, thread_id, :_}, :_})
    |> Enum.map(fn {_table, {:cp, _thread_id, step}, _value} -> step end)
  end

  defp fetch(table, thread_id, step) do
    case :mnesia.dirty_read(table, {:cp, thread_id, step}) do
      [{_table, _key, checkpoint}] -> {:ok, checkpoint}
      [] -> :not_found
    end
  end

  defp prune(%{keep: :all}, _thread_id), do: :ok

  defp prune(%{table: table, keep: {:last, n}}, thread_id) do
    steps = table |> cp_steps(thread_id) |> Enum.sort()

    for step <- Enum.drop(steps, -n) do
      :mnesia.dirty_delete(table, {:cp, thread_id, step})
      :mnesia.dirty_delete(table, {:wr, thread_id, step})
    end

    :ok
  end
end
