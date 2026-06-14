defmodule ElGraph.Checkpointer.Redis do
  @moduledoc """
  Redis/**Valkey** 기반 내구 체크포인터 (`ElGraph.Checkpointer` 어댑터, Redix 사용).

  메모리 DB지만 RDB/AOF 영속화를 켜면 재시작을 넘어 체크포인트가 보존된다 — 빠른 읽기/쓰기와
  내구성을 함께 얻는 선택지. Valkey(=Redis 포크, RESP 호환)와 Redis 모두 동작한다.

      {:ok, conn} = Redix.start_link(host: "localhost", port: 6379, name: :el_graph_redix)
      cp = {ElGraph.Checkpointer.Redis, ElGraph.Checkpointer.Redis.config(:el_graph_redix)}
      ElGraph.invoke(graph, input, checkpointer: cp, thread_id: "t1")

  저장 구조(키 prefix 기본 `"el_graph"`):
    * `<p>:cp:<thread>:<step>`  → `term_to_binary(checkpoint)`
    * `<p>:idx:<thread>`        → step 정렬용 sorted set(score=step) — `:latest`/`list` 순서 보장
    * `<p>:wr:<thread>:<step>`  → `term_to_binary(writes)` (pending writes)

  체크포인트는 `:erlang.term_to_binary/1`로 직렬화한다(RESP는 바이너리 안전). 허용되지 않는 항은
  `put` 전에 `ElGraph.Checkpoint`가 거부한다.
  """

  @behaviour ElGraph.Checkpointer

  alias ElGraph.Checkpoint

  @doc """
  어댑터 config — Redix 연결과 키 prefix를 지정한다.

      ElGraph.Checkpointer.Redis.config(:el_graph_redix, prefix: "myapp")
  """
  @spec config(GenServer.server(), keyword()) :: map()
  def config(conn, opts \\ []) do
    %{conn: conn, prefix: Keyword.get(opts, :prefix, "el_graph")}
  end

  @impl true
  def put(%{conn: conn, prefix: p}, %Checkpoint{} = checkpoint) do
    with :ok <- Checkpoint.validate_serializable(checkpoint.state) do
      {:ok, _} =
        Redix.pipeline(conn, [
          [
            "SET",
            cp_key(p, checkpoint.thread_id, checkpoint.step),
            :erlang.term_to_binary(checkpoint)
          ],
          [
            "ZADD",
            idx_key(p, checkpoint.thread_id),
            Integer.to_string(checkpoint.step),
            Integer.to_string(checkpoint.step)
          ]
        ])

      :ok
    end
  end

  @impl true
  def get(%{conn: conn, prefix: p}, thread_id, :latest) do
    case Redix.command(conn, ["ZRANGE", idx_key(p, thread_id), "-1", "-1"]) do
      {:ok, [step_str]} -> fetch_checkpoint(conn, p, thread_id, String.to_integer(step_str))
      {:ok, []} -> :not_found
    end
  end

  def get(%{conn: conn, prefix: p}, thread_id, step) when is_integer(step) do
    fetch_checkpoint(conn, p, thread_id, step)
  end

  @impl true
  def put_writes(%{conn: conn, prefix: p}, thread_id, step, writes) do
    with :ok <- Checkpoint.validate_serializable(writes) do
      {:ok, _} =
        Redix.command(conn, ["SET", wr_key(p, thread_id, step), :erlang.term_to_binary(writes)])

      :ok
    end
  end

  @impl true
  def get_writes(%{conn: conn, prefix: p}, thread_id, step) do
    case Redix.command(conn, ["GET", wr_key(p, thread_id, step)]) do
      {:ok, nil} -> []
      {:ok, data} -> :erlang.binary_to_term(data)
    end
  end

  @impl true
  def list(%{conn: conn, prefix: p}, thread_id) do
    {:ok, members} = Redix.command(conn, ["ZRANGE", idx_key(p, thread_id), "0", "-1"])
    steps = Enum.map(members, &String.to_integer/1)

    case steps do
      [] ->
        []

      _ ->
        {:ok, datas} =
          Redix.pipeline(conn, Enum.map(steps, &["GET", cp_key(p, thread_id, &1)]))

        Enum.zip(steps, datas)
        |> Enum.map(fn {step, data} ->
          %{step: step, version: :erlang.binary_to_term(data).version}
        end)
    end
  end

  defp fetch_checkpoint(conn, prefix, thread_id, step) do
    case Redix.command(conn, ["GET", cp_key(prefix, thread_id, step)]) do
      {:ok, nil} -> :not_found
      {:ok, data} -> {:ok, :erlang.binary_to_term(data)}
    end
  end

  defp cp_key(p, thread_id, step), do: "#{p}:cp:#{thread_id}:#{step}"
  defp wr_key(p, thread_id, step), do: "#{p}:wr:#{thread_id}:#{step}"
  defp idx_key(p, thread_id), do: "#{p}:idx:#{thread_id}"
end
