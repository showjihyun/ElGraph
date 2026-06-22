defmodule ElTrace.SessionsTest do
  use ExUnit.Case, async: true

  alias ElTrace.Sessions

  setup do
    pid = start_supervised!(Sessions)
    %{table: Sessions.table(pid)}
  end

  describe "register/5 + get/2" do
    test "registers a session and reads it back", %{table: t} do
      graph = :fake_graph
      cp = {FakeCP, %{ref: :tbl}}

      assert :ok = Sessions.register(t, "thread-1", graph, cp)

      assert {:ok, %{thread_id: "thread-1", graph: ^graph, checkpointer: ^cp, parent: nil}} =
               Sessions.get(t, "thread-1")
    end

    test "unknown thread returns :error", %{table: t} do
      assert :error = Sessions.get(t, "nope")
    end

    test "records fork lineage via :parent", %{table: t} do
      Sessions.register(t, "fork", :g, {FakeCP, %{}}, parent: "orig")
      assert {:ok, %{parent: "orig"}} = Sessions.get(t, "fork")
    end

    test "re-registering the same thread overwrites", %{table: t} do
      Sessions.register(t, "a", :g1, {FakeCP, %{}})
      Sessions.register(t, "a", :g2, {FakeCP, %{}})
      assert {:ok, %{graph: :g2}} = Sessions.get(t, "a")
    end
  end

  describe "list/1" do
    test "returns all registered sessions", %{table: t} do
      Sessions.register(t, "a", :g, {FakeCP, %{}})
      Sessions.register(t, "b", :g, {FakeCP, %{}}, parent: "a")

      ids = t |> Sessions.list() |> Enum.map(& &1.thread_id) |> Enum.sort()
      assert ids == ["a", "b"]
    end

    test "empty registry lists nothing", %{table: t} do
      assert Sessions.list(t) == []
    end
  end

  describe "cap eviction" do
    test "evicts the oldest session beyond the max cap (bounded memory)" do
      pid = start_supervised!({Sessions, max: 2}, id: :capped_sessions)
      t = Sessions.table(pid)

      for i <- 1..3, do: Sessions.register(t, "s#{i}", :g, {FakeCP, %{}})

      ids = t |> Sessions.list() |> Enum.map(& &1.thread_id) |> Enum.sort()
      assert ids == ["s2", "s3"]
    end
  end

  describe "PubSub" do
    test "register broadcasts :sessions_changed to subscribers", %{table: t} do
      Phoenix.PubSub.subscribe(ElTrace.PubSub, "sessions")
      Sessions.register(t, "x", :g, {FakeCP, %{}})
      assert_receive :sessions_changed
    end
  end
end
