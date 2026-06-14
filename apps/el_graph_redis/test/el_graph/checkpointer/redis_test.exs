defmodule ElGraph.Checkpointer.RedisTest do
  use ExUnit.Case, async: true
  @moduletag :redis

  alias ElGraph.Checkpointer.Redis

  setup do
    # 테스트별 고유 prefix로 격리(async 안전).
    prefix = "test:#{System.unique_integer([:positive])}"
    %{mod: Redis, config: Redis.config(:el_graph_test_redix, prefix: prefix)}
  end

  use ElGraph.CheckpointerContract

  describe "Valkey/Redis 특이사항" do
    test "config는 연결과 prefix를 담는다", %{config: config} do
      assert %{conn: :el_graph_test_redix, prefix: "test:" <> _} = config
    end

    test "다른 config 핸들로도 영속 데이터가 보인다 (in-memory 상태 비의존)", %{config: config} do
      :ok = Redis.put(config, %ElGraph.Checkpoint{thread_id: "dur", step: 0, state: %{v: 1}})
      fresh = Redis.config(:el_graph_test_redix, prefix: config.prefix)
      assert {:ok, %ElGraph.Checkpoint{state: %{v: 1}}} = Redis.get(fresh, "dur", :latest)
    end
  end

  describe "keep policy (SPEC §3.5 보존 정책)" do
    test "keep: {:last, n} prunes older checkpoints and their writes on put", %{config: base} do
      config = %{base | keep: {:last, 2}}

      for step <- 0..4 do
        :ok = Redis.put(config, %ElGraph.Checkpoint{thread_id: "t", step: step, state: %{}})
        :ok = Redis.put_writes(config, "t", step, [{:a, %{}}])
      end

      assert [%{step: 3}, %{step: 4}] = Redis.list(config, "t")
      assert :not_found = Redis.get(config, "t", 0)
      assert [] = Redis.get_writes(config, "t", 0)
      assert {:ok, %ElGraph.Checkpoint{step: 4}} = Redis.get(config, "t", :latest)
    end
  end
end
