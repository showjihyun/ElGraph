defmodule ElGraph.Checkpointer.ETSTest do
  use ExUnit.Case, async: true

  alias ElGraph.Checkpointer.ETS

  setup do
    pid = start_supervised!(ETS)
    %{mod: ETS, config: ETS.config(pid)}
  end

  use ElGraph.CheckpointerContract

  describe "keep policy (SPEC §3.5 보존 정책)" do
    test "keep: {:last, n} prunes older checkpoints on put", %{mod: mod} do
      pid = start_supervised!({ETS, keep: {:last, 2}}, id: :keeper)
      config = ETS.config(pid)

      for step <- 0..4 do
        :ok =
          mod.put(config, %ElGraph.Checkpoint{thread_id: "t", step: step, state: %{}, next: []})
      end

      assert [%{step: 3}, %{step: 4}] = mod.list(config, "t")
      assert :not_found = mod.get(config, "t", 0)
      assert {:ok, %ElGraph.Checkpoint{step: 4}} = mod.get(config, "t", :latest)
    end
  end

  describe "instance isolation (SPEC §3.5)" do
    test "two instances do not share checkpoints", %{mod: mod, config: config} do
      pid2 = start_supervised!({ETS, []}, id: :second_instance)
      config2 = ETS.config(pid2)

      :ok = mod.put(config, %ElGraph.Checkpoint{thread_id: "t", step: 0, state: %{}, next: []})

      assert {:ok, _checkpoint} = mod.get(config, "t", :latest)
      assert :not_found = mod.get(config2, "t", :latest)
    end
  end
end
