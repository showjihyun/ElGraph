defmodule ElGraph.Store.ETS do
  @moduledoc """
  ETS 기반 기본 장기 기억 Store (SPEC §6).

  체크포인터 ETS와 같은 패턴 — 인스턴스별 테이블(named 싱글턴 아님)이라
  `async: true` 테스트와 호환된다. DB 어댑터(Postgres 등)는 별도 패키지.

      children = [{ElGraph.Store.ETS, name: MyApp.Store}]
      config = ElGraph.Store.ETS.config(MyApp.Store)
      ElGraph.Store.ETS.put(config, ["users", "u1"], "theme", "dark")
  """

  @behaviour ElGraph.Store

  use GenServer

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @spec config(GenServer.server()) :: map()
  def config(server), do: GenServer.call(server, :config)

  @impl GenServer
  def init(_opts) do
    table = :ets.new(:el_graph_store, [:set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call(:config, _from, state), do: {:reply, state, state}

  @impl ElGraph.Store
  def put(%{table: table}, namespace, key, value) do
    true = :ets.insert(table, {{namespace, key}, value})
    :ok
  end

  @impl ElGraph.Store
  def get(%{table: table}, namespace, key) do
    case :ets.lookup(table, {namespace, key}) do
      [{_k, value}] -> {:ok, value}
      [] -> :not_found
    end
  end

  @impl ElGraph.Store
  def delete(%{table: table}, namespace, key) do
    true = :ets.delete(table, {namespace, key})
    :ok
  end

  @impl ElGraph.Store
  def list(%{table: table}, namespace) do
    table
    |> :ets.match_object({{namespace, :_}, :_})
    |> Enum.map(fn {{_ns, key}, value} -> {key, value} end)
  end
end
