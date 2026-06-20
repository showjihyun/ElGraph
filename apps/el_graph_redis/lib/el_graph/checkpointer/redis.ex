defmodule ElGraph.Checkpointer.Redis do
  @moduledoc """
  Redis/**Valkey** 기반 내구 체크포인터 (`ElGraph.Checkpointer` 어댑터, Redix 사용).

  메모리 DB지만 RDB/AOF 영속화를 켜면 재시작을 넘어 체크포인트가 보존된다 — 빠른 읽기/쓰기와
  내구성을 함께 얻는 선택지. **Valkey(=Redis 7.2 포크)와 Redis 모두 동작한다** — 쓰는 명령이
  `GET/SET/DEL/ZADD/ZRANGE/ZREM`(보편 핵심 RESP) 뿐이고 범용 Redix 클라이언트로 호출하므로
  Valkey-특화 코드가 없다. 테스트는 `REDIS_HOST`/`REDIS_PORT`를 Valkey 인스턴스로 가리키면
  동일 `:redis` 스위트가 Valkey를 검증한다(test_helper가 연결된 백엔드를 출력).

      {:ok, conn} = Redix.start_link(host: "localhost", port: 6379, name: :el_graph_redix)
      cp = {ElGraph.Checkpointer.Redis, ElGraph.Checkpointer.Redis.config(:el_graph_redix)}
      ElGraph.invoke(graph, input, checkpointer: cp, thread_id: "t1")

  저장 구조(키 prefix 기본 `"el_graph"`):
    * `<p>:cp:<thread>:<step>`  → `term_to_binary(checkpoint)`
    * `<p>:idx:<thread>`        → step 정렬용 sorted set(score=step) — `:latest`/`list` 순서 보장
    * `<p>:wr:<thread>:<step>`  → `term_to_binary(writes)` (pending writes)

  체크포인트는 `:erlang.term_to_binary/1`로 직렬화한다(RESP는 바이너리 안전). 허용되지 않는 항은
  `put` 전에 `ElGraph.Checkpoint`가 거부한다. 역직렬화는 `binary_to_term/2`를 `[:safe]`로 호출해
  Redis/Valkey가 변조되더라도 새 atom/함수 생성(atom 고갈·RCE 표면)을 막는다.
  """

  @behaviour ElGraph.Checkpointer

  alias ElGraph.Checkpoint

  @doc """
  어댑터 config — Redix 연결, 키 prefix, 보존정책을 지정한다.

      ElGraph.Checkpointer.Redis.config(:el_graph_redix, prefix: "myapp")
      ElGraph.Checkpointer.Redis.config(:el_graph_redix, keep: {:last, 50})
  """
  @spec config(GenServer.server(), keyword()) :: map()
  def config(conn, opts \\ []) do
    %{
      conn: conn,
      prefix: Keyword.get(opts, :prefix, "el_graph"),
      keep: Keyword.get(opts, :keep, :all)
    }
  end

  @impl true
  def put(%{conn: conn, prefix: p} = config, %Checkpoint{} = checkpoint) do
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

      prune(config, checkpoint.thread_id)
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
      {:ok, data} -> :erlang.binary_to_term(data, [:safe])
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
          %{step: step, version: :erlang.binary_to_term(data, [:safe]).version}
        end)
    end
  end

  defp fetch_checkpoint(conn, prefix, thread_id, step) do
    case Redix.command(conn, ["GET", cp_key(prefix, thread_id, step)]) do
      {:ok, nil} -> :not_found
      {:ok, data} -> {:ok, :erlang.binary_to_term(data, [:safe])}
    end
  end

  # 보존 정책 (SPEC §3.5): {:last, n}이면 thread별 최근 n개 step만 남기고 오래된
  # 체크포인트/pending writes 키와 인덱스 멤버를 정리한다.
  defp prune(%{keep: :all}, _thread_id), do: :ok

  defp prune(%{conn: conn, prefix: p, keep: {:last, n}}, thread_id) do
    {:ok, members} = Redix.command(conn, ["ZRANGE", idx_key(p, thread_id), "0", "-1"])
    old = Enum.drop(members, -n)

    if old != [] do
      del_keys =
        Enum.flat_map(old, fn step_str ->
          step = String.to_integer(step_str)
          [cp_key(p, thread_id, step), wr_key(p, thread_id, step)]
        end)

      Redix.pipeline(conn, [
        ["DEL" | del_keys],
        ["ZREM", idx_key(p, thread_id) | old]
      ])
    end

    :ok
  end

  defp cp_key(p, thread_id, step), do: "#{p}:cp:#{thread_id}:#{step}"
  defp wr_key(p, thread_id, step), do: "#{p}:wr:#{thread_id}:#{step}"
  defp idx_key(p, thread_id), do: "#{p}:idx:#{thread_id}"
end
