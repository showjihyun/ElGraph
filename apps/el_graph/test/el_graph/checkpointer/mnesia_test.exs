defmodule ElGraph.Checkpointer.MnesiaTest do
  use ExUnit.Case, async: true

  alias ElGraph.Checkpointer.Mnesia

  # 테스트는 ram_copies로 — disc 스키마(node-global) 설정 없이 어댑터 로직만 검증한다.
  # 프로덕션 기본은 disc_copies(영속). 테이블명을 테스트별 고유로 둬 async 격리.
  defp uniq(tag), do: :"el_graph_mnesia_#{tag}_#{System.unique_integer([:positive])}"

  setup do
    pid = start_supervised!({Mnesia, table: uniq("contract"), copies: :ram_copies})
    %{mod: Mnesia, config: Mnesia.config(pid)}
  end

  use ElGraph.CheckpointerContract

  describe "keep policy (SPEC §3.5 보존 정책)" do
    test "keep: {:last, n} prunes older checkpoints and their writes on put" do
      pid =
        start_supervised!(
          {Mnesia, table: uniq("keep"), copies: :ram_copies, keep: {:last, 2}},
          id: :keeper
        )

      config = Mnesia.config(pid)

      for step <- 0..4 do
        :ok = Mnesia.put(config, %ElGraph.Checkpoint{thread_id: "t", step: step, state: %{}})
        :ok = Mnesia.put_writes(config, "t", step, [{:a, %{}}])
      end

      assert [%{step: 3}, %{step: 4}] = Mnesia.list(config, "t")
      assert :not_found = Mnesia.get(config, "t", 0)
      assert [] = Mnesia.get_writes(config, "t", 0)
      assert {:ok, %ElGraph.Checkpoint{step: 4}} = Mnesia.get(config, "t", :latest)
    end
  end
end
