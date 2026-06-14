defmodule ElGraph.MemoryTest do
  use ExUnit.Case, async: true

  alias ElGraph.Memory
  alias ElGraph.Store.ETS, as: Store

  # Deterministic test embedder: char-frequency vector over a-z.
  # Lexically similar strings produce closer vectors → higher cosine similarity.
  defmodule CharEmbedder do
    @behaviour ElGraph.Memory.Embedder

    @impl true
    def embed(text) do
      freq =
        text
        |> String.downcase()
        |> String.to_charlist()
        |> Enum.filter(&(&1 in ?a..?z))
        |> Enum.frequencies()

      for c <- ?a..?z, do: Map.get(freq, c, 0) / 1.0
    end
  end

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

  describe "semantic recall — relevance by cosine similarity" do
    test "ranks the most lexically-similar episode first", %{mem: mem} do
      :ok = Memory.record_episode(mem, @ns, "billing and pricing questions", at: 1)
      :ok = Memory.record_episode(mem, @ns, "quantum field theory lecture", at: 2)
      :ok = Memory.record_episode(mem, @ns, "zzz xxx www", at: 3)

      [top | _] =
        Memory.recall_relevant(mem, @ns, "billing and pricing questions", embedder: CharEmbedder)

      assert top == "billing and pricing questions"
    end

    test "honors the limit", %{mem: mem} do
      :ok = Memory.record_episode(mem, @ns, "alpha", at: 1)
      :ok = Memory.record_episode(mem, @ns, "alpine", at: 2)
      :ok = Memory.record_episode(mem, @ns, "almanac", at: 3)

      results = Memory.recall_relevant(mem, @ns, "alpha", embedder: CharEmbedder, limit: 2)
      assert length(results) == 2
    end

    test "skips entries whose value is not a binary", %{mem: mem} do
      :ok = Memory.record_episode(mem, @ns, "text value", at: 1)
      :ok = Memory.record_episode(mem, @ns, %{not: "a string"}, at: 2)

      results = Memory.recall_relevant(mem, @ns, "text value", embedder: CharEmbedder)
      assert results == ["text value"]
    end

    test "supports the semantic scope", %{mem: mem} do
      :ok = Memory.set_fact(mem, @ns, "plan", "professional tier", at: 1)
      :ok = Memory.set_fact(mem, @ns, "region", "europe west", at: 2)

      [top | _] =
        Memory.recall_relevant(mem, @ns, "professional tier",
          embedder: CharEmbedder,
          scope: "semantic"
        )

      assert top == "professional tier"
    end
  end

  describe "supersede history for semantic facts" do
    test "keeps superseded values most-recent-first while latest still wins", %{mem: mem} do
      :ok = Memory.set_fact(mem, @ns, "plan", "free", at: 1)
      :ok = Memory.set_fact(mem, @ns, "plan", "pro", at: 2)

      assert {:ok, "pro"} = Memory.get_fact(mem, @ns, "plan")
      assert [%{value: "free", at: 1}] = Memory.fact_history(mem, @ns, "plan")
    end

    test "orders multiple prior values newest-first", %{mem: mem} do
      :ok = Memory.set_fact(mem, @ns, "plan", "free", at: 1)
      :ok = Memory.set_fact(mem, @ns, "plan", "pro", at: 2)
      :ok = Memory.set_fact(mem, @ns, "plan", "enterprise", at: 3)

      assert {:ok, "enterprise"} = Memory.get_fact(mem, @ns, "plan")

      assert [%{value: "pro", at: 2}, %{value: "free", at: 1}] =
               Memory.fact_history(mem, @ns, "plan")
    end

    test "returns [] for a subject with no prior values", %{mem: mem} do
      :ok = Memory.set_fact(mem, @ns, "plan", "free", at: 1)
      assert [] = Memory.fact_history(mem, @ns, "plan")
    end
  end

  describe "forget" do
    test "forgets a semantic fact", %{mem: mem} do
      :ok = Memory.set_fact(mem, @ns, "plan", "pro", at: 1)
      assert :ok = Memory.forget(mem, @ns, :semantic, "plan")
      assert :unknown = Memory.get_fact(mem, @ns, "plan")
    end

    test "forgets a procedural rule", %{mem: mem} do
      :ok = Memory.learn(mem, @ns, "greeting", "be formal")
      assert :ok = Memory.forget(mem, @ns, :procedural, "greeting")
      assert %{} == Memory.recall_rules(mem, @ns)
    end
  end
end
