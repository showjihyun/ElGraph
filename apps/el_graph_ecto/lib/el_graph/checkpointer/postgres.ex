defmodule ElGraph.Checkpointer.Postgres do
  @moduledoc """
  Postgres 기반 내구 체크포인터 (`ElGraph.Checkpointer` 어댑터).

  ETS 어댑터가 in-memory(노드 재시작 시 소실)인 것과 달리, 체크포인트를 Postgres에 영속화해
  VM/노드 재시작을 넘어 thread를 재개할 수 있다 — ElGraph의 "내구 실행" 약속을 실제로 보장한다.

      cp = {ElGraph.Checkpointer.Postgres, ElGraph.Checkpointer.Postgres.config(MyApp.Repo)}
      ElGraph.invoke(graph, input, checkpointer: cp, thread_id: "t1")

  체크포인트는 `:erlang.term_to_binary/1`로 직렬화해 `bytea`로 저장한다. `ElGraph.Checkpoint`가
  허용하지 않는 항(pid/ref/port/로컬 함수)은 `put` 전에 거부되므로 직렬화는 항상 안전하다.
  스키마는 `ElGraphEcto.Migration` 참조.
  """

  @behaviour ElGraph.Checkpointer

  alias ElGraph.Checkpoint
  alias Ecto.Adapters.SQL

  @doc "어댑터 config — 사용할 Ecto Repo를 지정한다(기본 `ElGraphEcto.Repo`)."
  @spec config(module()) :: map()
  def config(repo \\ ElGraphEcto.Repo), do: %{repo: repo}

  @impl true
  def put(%{repo: repo}, %Checkpoint{} = checkpoint) do
    with :ok <- Checkpoint.validate_serializable(checkpoint.state) do
      SQL.query!(
        repo,
        """
        INSERT INTO el_graph_checkpoints (thread_id, step, version, data)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (thread_id, step)
        DO UPDATE SET version = EXCLUDED.version, data = EXCLUDED.data
        """,
        [
          checkpoint.thread_id,
          checkpoint.step,
          checkpoint.version,
          :erlang.term_to_binary(checkpoint)
        ]
      )

      :ok
    end
  end

  @impl true
  def get(%{repo: repo}, thread_id, :latest) do
    repo
    |> SQL.query!(
      "SELECT data FROM el_graph_checkpoints WHERE thread_id = $1 ORDER BY step DESC LIMIT 1",
      [thread_id]
    )
    |> one_checkpoint()
  end

  def get(%{repo: repo}, thread_id, step) when is_integer(step) do
    repo
    |> SQL.query!(
      "SELECT data FROM el_graph_checkpoints WHERE thread_id = $1 AND step = $2",
      [thread_id, step]
    )
    |> one_checkpoint()
  end

  @impl true
  def put_writes(%{repo: repo}, thread_id, step, writes) do
    with :ok <- Checkpoint.validate_serializable(writes) do
      SQL.query!(
        repo,
        """
        INSERT INTO el_graph_writes (thread_id, step, data)
        VALUES ($1, $2, $3)
        ON CONFLICT (thread_id, step) DO UPDATE SET data = EXCLUDED.data
        """,
        [thread_id, step, :erlang.term_to_binary(writes)]
      )

      :ok
    end
  end

  @impl true
  def get_writes(%{repo: repo}, thread_id, step) do
    case SQL.query!(
           repo,
           "SELECT data FROM el_graph_writes WHERE thread_id = $1 AND step = $2",
           [thread_id, step]
         ) do
      %{rows: [[data]]} -> :erlang.binary_to_term(data)
      %{rows: []} -> []
    end
  end

  @impl true
  def list(%{repo: repo}, thread_id) do
    %{rows: rows} =
      SQL.query!(
        repo,
        "SELECT step, version FROM el_graph_checkpoints WHERE thread_id = $1 ORDER BY step ASC",
        [thread_id]
      )

    Enum.map(rows, fn [step, version] -> %{step: step, version: version} end)
  end

  defp one_checkpoint(%{rows: [[data]]}), do: {:ok, :erlang.binary_to_term(data)}
  defp one_checkpoint(%{rows: []}), do: :not_found
end
