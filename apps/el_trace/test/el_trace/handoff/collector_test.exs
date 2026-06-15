defmodule ElTrace.Handoff.CollectorTest do
  use ExUnit.Case, async: true

  alias ElTrace.Handoff.Collector

  defp execute(edge) do
    :telemetry.execute([:el_graph, :agent, :handoff], %{}, edge)
  end

  # All live collectors share the one global [:el_graph, :agent, :handoff] event,
  # so under async every collector also sees other tests' emits. Each test uses a
  # unique tag and filters edges to its own, asserting on the slice it caused.
  defp mine(edges, tag), do: Enum.filter(edges, &(&1.from == tag))

  defp start_collector do
    start_supervised!(
      {Collector, name: :"collector_#{System.unique_integer([:positive])}"},
      id: System.unique_integer([:positive])
    )
  end

  test "accumulates edges from telemetry into a graph" do
    server = start_collector()
    tag = "from_#{System.unique_integer([:positive])}"

    execute(%{from: tag, to: "summarizer", signal: "research.done"})
    execute(%{from: tag, to: "writer", signal: "summary.done"})

    # edges/1 is a GenServer.call that flushes the prior telemetry casts.
    assert mine(Collector.edges(server), tag) == [
             %{from: tag, to: "summarizer", signal: "research.done"},
             %{from: tag, to: "writer", signal: "summary.done"}
           ]

    assert %{edges: edges} = Collector.graph(server)
    assert length(mine(edges, tag)) == 2
  end

  test "reset clears accumulated edges" do
    server = start_collector()
    tag = "from_#{System.unique_integer([:positive])}"

    execute(%{from: tag, to: "b", signal: "go"})
    assert mine(Collector.edges(server), tag) != []

    assert :ok = Collector.reset(server)
    assert Collector.edges(server) == []
  end

  test "build dedupes and sorts nodes via graph/1" do
    server = start_collector()
    tag = "from_#{System.unique_integer([:positive])}"

    execute(%{from: tag, to: tag <> "_z", signal: "go"})
    execute(%{from: tag, to: tag <> "_z", signal: "go"})

    assert %{nodes: nodes, edges: edges} = Collector.graph(server)
    assert tag in nodes
    # Identical (from, to, signal) triple collapses to a single edge.
    assert length(mine(edges, tag)) == 1
  end
end
