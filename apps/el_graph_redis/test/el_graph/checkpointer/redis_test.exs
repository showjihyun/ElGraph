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
end
