defmodule ElGraph.Checkpointer.PostgresTest do
  use ExUnit.Case, async: true
  @moduletag :postgres

  alias ElGraph.Checkpointer.Postgres
  alias ElGraphEcto.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    %{mod: Postgres, config: Postgres.config(Repo)}
  end

  use ElGraph.CheckpointerContract

  describe "durability (재시작 모사)" do
    test "config는 임의 Ecto Repo를 받는다", %{config: config} do
      assert %{repo: Repo} = config
    end

    test "다른 config(repo)로 같은 thread를 조회해도 영속 데이터가 보인다", %{config: config} do
      # Sandbox 트랜잭션 안에서 같은 Repo면 새 config 핸들로도 동일 데이터가 보인다
      # (= 어댑터가 in-memory 상태에 의존하지 않고 Postgres에 영속한다).
      :ok = Postgres.put(config, %ElGraph.Checkpoint{thread_id: "dur", step: 0, state: %{v: 1}})
      fresh = Postgres.config(Repo)
      assert {:ok, %ElGraph.Checkpoint{state: %{v: 1}}} = Postgres.get(fresh, "dur", :latest)
    end
  end
end
