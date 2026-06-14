defmodule ElGraph.Checkpointer.DetsTest do
  use ExUnit.Case, async: true

  alias ElGraph.Checkpointer.Dets

  defp temp_path(tag),
    do:
      Path.join(
        System.tmp_dir!(),
        "el_graph_dets_#{tag}_#{System.unique_integer([:positive])}.dets"
      )

  setup do
    path = temp_path("contract")
    pid = start_supervised!({Dets, path: path})
    on_exit(fn -> File.rm(path) end)
    %{mod: Dets, config: Dets.config(pid)}
  end

  use ElGraph.CheckpointerContract

  describe "keep policy (SPEC §3.5 보존 정책)" do
    test "keep: {:last, n} prunes older checkpoints and their writes on put" do
      path = temp_path("keep")
      pid = start_supervised!({Dets, path: path, keep: {:last, 2}}, id: :keeper)
      on_exit(fn -> File.rm(path) end)
      config = Dets.config(pid)

      for step <- 0..4 do
        :ok = Dets.put(config, %ElGraph.Checkpoint{thread_id: "t", step: step, state: %{}})
        :ok = Dets.put_writes(config, "t", step, [{:a, %{}}])
      end

      assert [%{step: 3}, %{step: 4}] = Dets.list(config, "t")
      assert :not_found = Dets.get(config, "t", 0)
      assert [] = Dets.get_writes(config, "t", 0)
      assert {:ok, %ElGraph.Checkpoint{step: 4}} = Dets.get(config, "t", :latest)
    end
  end

  describe "durability (디스크 영속 — VM 재시작 모사)" do
    test "reopening the same file resumes checkpoints after the owner stops" do
      path = temp_path("dur")
      on_exit(fn -> File.rm(path) end)

      pid1 = start_supervised!({Dets, path: path}, id: :first)

      :ok =
        Dets.put(Dets.config(pid1), %ElGraph.Checkpoint{thread_id: "t", step: 0, state: %{v: 1}})

      :ok = stop_supervised(:first)

      pid2 = start_supervised!({Dets, path: path}, id: :second)

      assert {:ok, %ElGraph.Checkpoint{state: %{v: 1}}} =
               Dets.get(Dets.config(pid2), "t", :latest)
    end
  end
end
