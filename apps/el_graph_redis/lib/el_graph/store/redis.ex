defmodule ElGraph.Store.Redis do
  @moduledoc """
  Redis/**Valkey** 기반 내구 장기기억 Store (`ElGraph.Store` 어댑터, Redix 사용).

  `ElGraph.Memory`의 저장소로 쓰면 3-스코프·시점진실·temporal·충돌해소 facts가
  Valkey에 영속된다(체크포인터가 thread 단위 단기 상태라면 Store는 thread를 가로지른다).
  Valkey/Redis 모두 동작한다 — `HSET/HGET/HDEL/HGETALL`(보편 핵심 RESP)만 쓴다.

      {:ok, conn} = Redix.start_link(host: "localhost", port: 6379, name: :el_graph_redix)
      store = {ElGraph.Store.Redis, ElGraph.Store.Redis.config(:el_graph_redix)}
      mem = ElGraph.Memory.new(store)
      ElGraph.Memory.set_fact(mem, ["users", "u1"], "plan", "pro")

  저장 구조(키 prefix 기본 `"el_graph_store"`):
    * `<p>:ns:<namespace>` → namespace당 HASH (field=key, value=`term_to_binary(value)`)

  `list/2`는 HGETALL로 namespace 전체를 한 번에 돌려준다 — 별도 인덱스가 필요 없다.
  값은 `:erlang.term_to_binary/1`로 직렬화한다(RESP는 바이너리 안전).
  """

  @behaviour ElGraph.Store

  @doc """
  어댑터 config — Redix 연결과 키 prefix를 지정한다.

      ElGraph.Store.Redis.config(:el_graph_redix, prefix: "myapp_store")
  """
  @spec config(GenServer.server(), keyword()) :: map()
  def config(conn, opts \\ []) do
    %{conn: conn, prefix: Keyword.get(opts, :prefix, "el_graph_store")}
  end

  @impl ElGraph.Store
  def put(%{conn: conn, prefix: p}, namespace, key, value) do
    {:ok, _} =
      Redix.command(conn, ["HSET", ns_key(p, namespace), key, :erlang.term_to_binary(value)])

    :ok
  end

  @impl ElGraph.Store
  def get(%{conn: conn, prefix: p}, namespace, key) do
    case Redix.command(conn, ["HGET", ns_key(p, namespace), key]) do
      {:ok, nil} -> :not_found
      {:ok, data} -> {:ok, :erlang.binary_to_term(data)}
    end
  end

  @impl ElGraph.Store
  def delete(%{conn: conn, prefix: p}, namespace, key) do
    {:ok, _} = Redix.command(conn, ["HDEL", ns_key(p, namespace), key])
    :ok
  end

  @impl ElGraph.Store
  def list(%{conn: conn, prefix: p}, namespace) do
    {:ok, flat} = Redix.command(conn, ["HGETALL", ns_key(p, namespace)])

    flat
    |> Enum.chunk_every(2)
    |> Enum.map(fn [key, data] -> {key, :erlang.binary_to_term(data)} end)
  end

  defp ns_key(p, namespace), do: "#{p}:ns:#{Enum.join(namespace, ":")}"
end
