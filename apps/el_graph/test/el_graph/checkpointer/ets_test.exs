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

  describe "동시 prune 내성 (TOCTOU)" do
    test "get(:latest)/list가 동시 prune 중에도 크래시하지 않는다" do
      pid = start_supervised!({ETS, keep: {:last, 1}}, id: :toctou)
      config = ETS.config(pid)

      cp = fn s -> %ElGraph.Checkpoint{thread_id: "t", step: s, state: %{}, next: []} end

      writer = Task.async(fn -> for s <- 1..2000, do: ETS.put(config, cp.(s)) end)

      reader =
        Task.async(fn ->
          # prune(keep 1)이 prev와 lookup 사이에 최신 step을 지우면 예전엔 MatchError로 죽었다.
          for _ <- 1..2000, do: {ETS.get(config, "t", :latest), ETS.list(config, "t")}
        end)

      Task.await(writer, 10_000)
      Task.await(reader, 10_000)

      assert match?({:ok, _}, ETS.get(config, "t", :latest)) or
               ETS.get(config, "t", :latest) == :not_found
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
