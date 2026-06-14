defmodule ElTrace.ReplayTest do
  use ExUnit.Case, async: true

  alias ElTrace.Replay
  alias ElTrace.TestNodes
  alias ElGraph.Checkpointer.ETS

  # messages를 누적하며 각 노드가 한 글자씩 더한다 — fork 지점에 따라 결과가 갈린다.
  defp graph do
    ElGraph.new()
    |> ElGraph.state(:trail, default: "", reducer: {__MODULE__, :concat, []})
    |> ElGraph.add_node(:a, {TestNodes, :noop, []})
    |> ElGraph.add_node(:b, &__MODULE__.add_b/2)
    |> ElGraph.add_node(:c, &__MODULE__.add_c/2)
    |> ElGraph.add_edge(:a, :b)
    |> ElGraph.add_edge(:b, :c)
    |> ElGraph.compile(entry: :a)
  end

  def concat(cur, new), do: cur <> new
  def add_b(_s, _c), do: %{trail: "B"}
  def add_c(_s, _c), do: %{trail: "C"}

  setup do
    pid = start_supervised!(ETS)
    %{cp: {ETS, ETS.config(pid)}, config: ETS.config(pid)}
  end

  describe "from/5 — time-travel fork" do
    test "replays from an earlier step into a new thread", %{cp: cp} do
      {:ok, %{trail: "BC"}} = ElGraph.invoke(graph(), %{}, checkpointer: cp, thread_id: "orig")

      # step 2 = b 실행 직후(trail "B", next [:c]). 거기서 fork → c만 다시 → "BC".
      assert {:ok, %{trail: "BC"}} =
               Replay.from(cp, "orig", 2, graph(), as: "fork")
    end

    test "the original thread is preserved (fork writes to a separate thread)", %{
      cp: cp,
      config: config
    } do
      {:ok, _} = ElGraph.invoke(graph(), %{}, checkpointer: cp, thread_id: "orig")
      orig_before = ETS.list(config, "orig")

      {:ok, _} = Replay.from(cp, "orig", 1, graph(), as: "fork")

      assert ETS.list(config, "orig") == orig_before
      assert ETS.list(config, "fork") != []
    end

    test "default fork thread id is derived from source and step", %{cp: cp, config: config} do
      {:ok, _} = ElGraph.invoke(graph(), %{}, checkpointer: cp, thread_id: "orig")

      {:ok, _} = Replay.from(cp, "orig", 1, graph())

      assert ETS.list(config, "orig-replay-1") != []
    end
  end
end
