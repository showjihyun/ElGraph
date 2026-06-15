defmodule ElTrace.HandoffTest do
  use ExUnit.Case, async: true

  alias ElTrace.Handoff

  test "build collects unique sorted nodes and deduped edges" do
    edges = [
      %{from: "researcher", to: "summarizer", signal: "research.done"},
      %{from: "researcher", to: "summarizer", signal: "research.done"},
      %{from: "summarizer", to: "writer", signal: "summary.done"}
    ]

    assert %{nodes: nodes, edges: built} = Handoff.build(edges)
    assert nodes == ["researcher", "summarizer", "writer"]

    assert built == [
             %{from: "researcher", to: "summarizer", signal: "research.done"},
             %{from: "summarizer", to: "writer", signal: "summary.done"}
           ]
  end

  test "build on empty edges yields empty graph" do
    assert Handoff.build([]) == %{nodes: [], edges: []}
  end

  test "to_dot renders a digraph with labeled directed edges" do
    graph = Handoff.build([%{from: "a", to: "b", signal: "go"}])
    dot = Handoff.to_dot(graph)

    assert dot =~ "digraph handoff {"
    assert dot =~ ~s("a" -> "b" [label="go"];)
    assert dot =~ "}"
  end

  test "render produces text edge lines" do
    graph =
      Handoff.build([
        %{from: "a", to: "b", signal: "go"},
        %{from: "b", to: "c", signal: "next"}
      ])

    assert Handoff.render(graph) == "a --go--> b\nb --next--> c"
  end

  test "render on empty graph is an empty string" do
    assert Handoff.render(Handoff.build([])) == ""
  end
end
