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

  describe "safe deserialization (보안 — :safe)" do
    test "검증을 우회해 직접 심은 unsafe 페이로드(미등록 atom)는 :safe로 거부된다", %{config: config} do
      # 미등록 atom을 담은 ETF 바이트(문자열 보간이라 atom이 생성되지 않는다) — :safe면 거부.
      name = "elgraph_unknown_atom_#{System.unique_integer([:positive])}"
      evil = <<131, 119, byte_size(name)::8, name::binary>>

      Ecto.Adapters.SQL.query!(
        Repo,
        "INSERT INTO el_graph_checkpoints (thread_id, step, version, data) VALUES ($1, $2, $3, $4)",
        ["evil", 0, 1, evil]
      )

      assert_raise ArgumentError, fn -> Postgres.get(config, "evil", :latest) end
    end
  end

  describe "keep policy (SPEC §3.5 보존 정책)" do
    test "keep: {:last, n} prunes older checkpoints and their writes on put" do
      config = Postgres.config(Repo, keep: {:last, 2})

      for step <- 0..4 do
        :ok = Postgres.put(config, %ElGraph.Checkpoint{thread_id: "t", step: step, state: %{}})
        :ok = Postgres.put_writes(config, "t", step, [{:a, %{}}])
      end

      assert [%{step: 3}, %{step: 4}] = Postgres.list(config, "t")
      assert :not_found = Postgres.get(config, "t", 0)
      assert [] = Postgres.get_writes(config, "t", 0)
      assert {:ok, %ElGraph.Checkpoint{step: 4}} = Postgres.get(config, "t", :latest)
    end
  end
end
