defmodule ElGraph.MemoryTest do
  use ExUnit.Case, async: true

  alias ElGraph.Memory
  alias ElGraph.Store.ETS, as: Store

  setup do
    pid = start_supervised!({Store, []})
    %{mem: Memory.new({Store, Store.config(pid)})}
  end

  @ns ["users", "u1"]

  describe "episodic — time-ordered event log" do
    test "recalls episodes most-recent-first", %{mem: mem} do
      :ok = Memory.record_episode(mem, @ns, "asked about pricing", at: 1)
      :ok = Memory.record_episode(mem, @ns, "asked about limits", at: 2)
      :ok = Memory.record_episode(mem, @ns, "asked about SLAs", at: 3)

      assert ["asked about SLAs", "asked about limits", "asked about pricing"] =
               Memory.recall_episodes(mem, @ns)
    end

    test "honors a recall limit", %{mem: mem} do
      for i <- 1..5, do: Memory.record_episode(mem, @ns, "e#{i}", at: i)
      assert ["e5", "e4"] = Memory.recall_episodes(mem, @ns, limit: 2)
    end

    test "episodes are isolated per namespace", %{mem: mem} do
      :ok = Memory.record_episode(mem, ["users", "a"], "a-event", at: 1)
      :ok = Memory.record_episode(mem, ["users", "b"], "b-event", at: 1)
      assert ["a-event"] = Memory.recall_episodes(mem, ["users", "a"])
    end
  end

  describe "semantic — facts with temporal truth (latest wins)" do
    test "a newer fact supersedes an older one for the same subject", %{mem: mem} do
      :ok = Memory.set_fact(mem, @ns, "plan", "free", at: 1)
      :ok = Memory.set_fact(mem, @ns, "plan", "pro", at: 2)

      assert {:ok, "pro"} = Memory.get_fact(mem, @ns, "plan")
    end

    test "unknown subject returns :unknown", %{mem: mem} do
      assert :unknown = Memory.get_fact(mem, @ns, "nope")
    end

    test "recall_facts returns the current truth per subject", %{mem: mem} do
      :ok = Memory.set_fact(mem, @ns, "plan", "pro", at: 2)
      :ok = Memory.set_fact(mem, @ns, "region", "eu", at: 1)
      assert %{"plan" => "pro", "region" => "eu"} = Memory.recall_facts(mem, @ns)
    end
  end

  describe "procedural — learned rules" do
    test "learns and recalls rules by name", %{mem: mem} do
      :ok = Memory.learn(mem, @ns, "greeting", "always greet by first name")
      assert %{"greeting" => "always greet by first name"} = Memory.recall_rules(mem, @ns)
    end
  end
end
