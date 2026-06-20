defmodule ElGraph.Store.RedisTest do
  use ExUnit.Case, async: true
  @moduletag :redis

  alias ElGraph.Store.Redis

  setup do
    # 테스트별 고유 prefix로 격리(async 안전).
    prefix = "test:store:#{System.unique_integer([:positive])}"
    %{mod: Redis, config: Redis.config(:el_graph_test_redix, prefix: prefix)}
  end

  use ElGraph.StoreContract

  describe "Valkey/Redis 특이사항" do
    test "config는 연결과 prefix를 담는다", %{config: config} do
      assert %{conn: :el_graph_test_redix, prefix: "test:store:" <> _} = config
    end

    test "다른 config 핸들로도 영속 데이터가 보인다 (in-memory 상태 비의존)", %{config: config} do
      :ok = Redis.put(config, ["users", "u1"], "plan", "pro")
      fresh = Redis.config(:el_graph_test_redix, prefix: config.prefix)
      assert {:ok, "pro"} = Redis.get(fresh, ["users", "u1"], "plan")
    end

    test "stores arbitrary terms (Memory facts) verbatim", %{config: config} do
      fact = %{value: "pro", at: 7}
      :ok = Redis.put(config, ["users", "u1", "semantic"], "plan", fact)
      assert {:ok, ^fact} = Redis.get(config, ["users", "u1", "semantic"], "plan")
    end
  end

  describe "safe deserialization (보안 — :safe)" do
    test "직접 심은 unsafe 값(미등록 atom)은 :safe로 거부된다", %{config: config} do
      name = "elgraph_unknown_atom_#{System.unique_integer([:positive])}"
      evil = <<131, 119, byte_size(name)::8, name::binary>>

      {:ok, _} =
        Redix.command(:el_graph_test_redix, ["HSET", "#{config.prefix}:ns:evil", "k", evil])

      assert_raise ArgumentError, fn -> Redis.get(config, ["evil"], "k") end
    end
  end

  describe "ElGraph.Memory persisted to Valkey" do
    test "facts (incl. temporal/conflict) survive a fresh Store handle", %{config: config} do
      mem = ElGraph.Memory.new({Redis, config})
      ns = ["users", "u1"]

      :ok = ElGraph.Memory.set_fact(mem, ns, "plan", "free", at: 1)
      :ok = ElGraph.Memory.set_fact(mem, ns, "plan", "pro", at: 3)

      # 새 핸들(인메모리 상태 비의존) — Valkey에서 다시 읽는다.
      fresh =
        ElGraph.Memory.new({Redis, Redis.config(:el_graph_test_redix, prefix: config.prefix)})

      assert {:ok, "pro"} = ElGraph.Memory.get_fact(fresh, ns, "plan")
      assert {:ok, "free"} = ElGraph.Memory.fact_at(fresh, ns, "plan", 2)
      assert [%{value: "free", at: 1}] = ElGraph.Memory.fact_history(fresh, ns, "plan")
    end
  end
end
