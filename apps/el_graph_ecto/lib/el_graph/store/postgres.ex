defmodule ElGraph.Store.Postgres do
  @moduledoc """
  Postgres 기반 내구 장기기억 Store (`ElGraph.Store` 어댑터).

  `ElGraph.Memory`의 저장소로 쓰면 3-스코프·시점진실·temporal·충돌해소 facts가
  Postgres에 영속된다 — ETS Store가 in-memory(재시작 시 소실)인 것과 달리 VM/노드
  재시작을 넘어 보존한다(체크포인터가 thread 단위 단기 상태라면 Store는 thread를 가로지른다).

      store = {ElGraph.Store.Postgres, ElGraph.Store.Postgres.config(MyApp.Repo)}
      mem = ElGraph.Memory.new(store)
      ElGraph.Memory.set_fact(mem, ["users", "u1"], "plan", "pro")

  `namespace`는 `text[]`로 저장하고, `value`는 `:erlang.term_to_binary/1`로 직렬화해 `bytea`로
  저장한다(atom/tuple/map 등 Elixir 항 손실 없음). 역직렬화는 `binary_to_term/2`를 `[:safe]`로
  호출해 DB 변조 시 새 atom/함수 생성을 막는다. 스키마는 `ElGraphEcto.StoreMigration` 참조.
  """

  @behaviour ElGraph.Store

  alias Ecto.Adapters.SQL

  @doc """
  어댑터 config — 사용할 Ecto Repo를 지정한다.

      ElGraph.Store.Postgres.config(MyApp.Repo)
  """
  @spec config(module()) :: map()
  def config(repo \\ ElGraphEcto.Repo), do: %{repo: repo}

  @impl ElGraph.Store
  def put(%{repo: repo}, namespace, key, value) do
    SQL.query!(
      repo,
      """
      INSERT INTO el_graph_store (namespace, key, value)
      VALUES ($1::text[], $2, $3)
      ON CONFLICT (namespace, key) DO UPDATE SET value = EXCLUDED.value
      """,
      [namespace, key, :erlang.term_to_binary(value)]
    )

    :ok
  end

  @impl ElGraph.Store
  def get(%{repo: repo}, namespace, key) do
    case SQL.query!(
           repo,
           "SELECT value FROM el_graph_store WHERE namespace = $1::text[] AND key = $2",
           [namespace, key]
         ) do
      %{rows: [[data]]} -> {:ok, :erlang.binary_to_term(data, [:safe])}
      %{rows: []} -> :not_found
    end
  end

  @impl ElGraph.Store
  def delete(%{repo: repo}, namespace, key) do
    SQL.query!(
      repo,
      "DELETE FROM el_graph_store WHERE namespace = $1::text[] AND key = $2",
      [namespace, key]
    )

    :ok
  end

  @impl ElGraph.Store
  def list(%{repo: repo}, namespace) do
    %{rows: rows} =
      SQL.query!(
        repo,
        "SELECT key, value FROM el_graph_store WHERE namespace = $1::text[]",
        [namespace]
      )

    Enum.map(rows, fn [key, data] -> {key, :erlang.binary_to_term(data, [:safe])} end)
  end
end
