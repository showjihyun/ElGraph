defmodule ElGraph.Checkpointer.Dets do
  @moduledoc """
  DETS(디스크 ETS) 기반 내구 체크포인터 — **외부 인프라 0**의 단일 노드 영속 옵션.

  ETS 어댑터가 VM 종료 시 소실되는 것과 달리, DETS는 단일 파일에 디스크 영속하므로 VM/노드
  재시작을 넘어 thread를 재개한다. Postgres/Valkey 같은 별도 서버 없이 "내구 실행"을 얻는다
  (대신 단일 노드·파일 2GB 한계·분산 없음 — 멀티노드는 `ElGraph.Checkpointer.Mnesia` 참조).

      children = [{ElGraph.Checkpointer.Dets, path: "/var/lib/myapp/checkpoints.dets"}]
      cp = {ElGraph.Checkpointer.Dets, ElGraph.Checkpointer.Dets.config(pid)}

  ETS 어댑터처럼 인스턴스별(파일별) — 소유 GenServer가 파일 수명을 관리하고, 읽기/쓰기는
  DETS 테이블에 직접 수행한다. `keep: {:last, n}`으로 오래된 체크포인트를 정리한다.
  """

  @behaviour ElGraph.Checkpointer

  use GenServer

  alias ElGraph.Checkpoint

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "이 인스턴스의 config(테이블 핸들 + 보존정책)를 반환한다."
  @spec config(GenServer.server()) :: map()
  def config(server), do: GenServer.call(server, :config)

  @impl GenServer
  def init(opts) do
    path = Keyword.get(opts, :path) || default_path()
    File.mkdir_p!(Path.dirname(path))

    table = :"el_graph_dets_#{System.unique_integer([:positive])}"
    {:ok, ^table} = :dets.open_file(table, file: String.to_charlist(path), type: :set)

    {:ok, %{table: table, keep: Keyword.get(opts, :keep, :all)}}
  end

  @impl GenServer
  def handle_call(:config, _from, state), do: {:reply, Map.take(state, [:table, :keep]), state}

  @impl GenServer
  def terminate(_reason, %{table: table}), do: :dets.close(table)

  @impl ElGraph.Checkpointer
  def put(%{table: table} = config, %Checkpoint{} = checkpoint) do
    with :ok <- Checkpoint.validate_serializable(checkpoint) do
      :ok = :dets.insert(table, {{:cp, checkpoint.thread_id, checkpoint.step}, checkpoint})
      prune(config, checkpoint.thread_id)
      :ok
    end
  end

  @impl ElGraph.Checkpointer
  def get(%{table: table}, thread_id, :latest) do
    case steps(table, thread_id) do
      [] -> :not_found
      list -> {:ok, fetch!(table, thread_id, Enum.max(list))}
    end
  end

  def get(%{table: table}, thread_id, step) when is_integer(step) do
    case :dets.lookup(table, {:cp, thread_id, step}) do
      [{_key, checkpoint}] -> {:ok, checkpoint}
      [] -> :not_found
    end
  end

  @impl ElGraph.Checkpointer
  def put_writes(%{table: table}, thread_id, step, writes) do
    with :ok <- Checkpoint.validate_serializable(writes) do
      :ok = :dets.insert(table, {{:wr, thread_id, step}, writes})
      :ok
    end
  end

  @impl ElGraph.Checkpointer
  def get_writes(%{table: table}, thread_id, step) do
    case :dets.lookup(table, {:wr, thread_id, step}) do
      [{_key, writes}] -> writes
      [] -> []
    end
  end

  @impl ElGraph.Checkpointer
  def list(%{table: table}, thread_id) do
    table
    |> steps(thread_id)
    |> Enum.sort()
    |> Enum.map(fn step -> %{step: step, version: fetch!(table, thread_id, step).version} end)
  end

  # DETS는 ordered_set이 없으므로 thread의 step을 모아 Elixir에서 정렬한다.
  defp steps(table, thread_id) do
    table |> :dets.match({{:cp, thread_id, :"$1"}, :_}) |> List.flatten()
  end

  defp fetch!(table, thread_id, step) do
    [{_key, checkpoint}] = :dets.lookup(table, {:cp, thread_id, step})
    checkpoint
  end

  defp prune(%{keep: :all}, _thread_id), do: :ok

  defp prune(%{table: table, keep: {:last, n}}, thread_id) do
    steps = table |> steps(thread_id) |> Enum.sort()

    for step <- Enum.drop(steps, -n) do
      :dets.delete(table, {:cp, thread_id, step})
      :dets.delete(table, {:wr, thread_id, step})
    end

    :ok
  end

  defp default_path,
    do: Path.join(System.tmp_dir!(), "el_graph_#{System.unique_integer([:positive])}.dets")
end
