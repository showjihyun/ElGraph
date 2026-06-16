defmodule ElGraph.Store.PostgresTest do
  use ExUnit.Case, async: true
  @moduletag :postgres

  alias ElGraph.Store.Postgres
  alias ElGraphEcto.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    %{mod: Postgres, config: Postgres.config(Repo)}
  end

  use ElGraph.StoreContract

  describe "Postgres 특이사항" do
    test "config는 임의 Ecto Repo를 받는다", %{config: config} do
      assert %{repo: Repo} = config
    end

    test "다른 config(repo) 핸들로도 영속 데이터가 보인다 (in-memory 상태 비의존)", %{config: config} do
      :ok = Postgres.put(config, ["users", "u1"], "plan", "pro")
      fresh = Postgres.config(Repo)
      assert {:ok, "pro"} = Postgres.get(fresh, ["users", "u1"], "plan")
    end

    test "stores arbitrary terms (Memory facts) verbatim", %{config: config} do
      fact = %{value: "pro", at: 7}
      :ok = Postgres.put(config, ["users", "u1", "semantic"], "plan", fact)
      assert {:ok, ^fact} = Postgres.get(config, ["users", "u1", "semantic"], "plan")
    end
  end

  describe "ElGraph.Memory persisted to Postgres" do
    test "facts (incl. temporal/conflict) survive a fresh Store handle", %{config: config} do
      mem = ElGraph.Memory.new({Postgres, config})
      ns = ["users", "u1"]

      :ok = ElGraph.Memory.set_fact(mem, ns, "plan", "free", at: 1)
      :ok = ElGraph.Memory.set_fact(mem, ns, "plan", "pro", at: 3)

      fresh = ElGraph.Memory.new({Postgres, Postgres.config(Repo)})

      assert {:ok, "pro"} = ElGraph.Memory.get_fact(fresh, ns, "plan")
      assert {:ok, "free"} = ElGraph.Memory.fact_at(fresh, ns, "plan", 2)
      assert [%{value: "free", at: 1}] = ElGraph.Memory.fact_history(fresh, ns, "plan")
    end
  end
end
