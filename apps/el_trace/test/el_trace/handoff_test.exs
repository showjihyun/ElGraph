defmodule ElTrace.HandoffTest do
  use ExUnit.Case, async: true

  alias ElTrace.Handoff

  doctest ElTrace.Handoff

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

  describe "to_svg/1 — server-side SVG (no JS deps)" do
    test "renders an svg with a node rect+label per agent and an arc per edge" do
      graph =
        Handoff.build([
          %{from: "researcher", to: "summarizer", signal: "research.done"},
          %{from: "summarizer", to: "writer", signal: "summary.done"}
        ])

      svg = Handoff.to_svg(graph)

      assert svg =~ "<svg"
      assert svg =~ "</svg>"
      # arrowhead marker defined
      assert svg =~ "<marker"
      # one rect per node (3 agents)
      assert length(Regex.scan(~r/<rect /, svg)) == 3
      # node labels + signal labels present
      assert svg =~ ">researcher<" and svg =~ ">summarizer<" and svg =~ ">writer<"
      assert svg =~ ">research.done<" and svg =~ ">summary.done<"
      # one path per edge (2)
      assert length(Regex.scan(~r/<path class="edge"/, svg)) == 2
    end

    test "escapes XML-special characters in names/signals" do
      svg = Handoff.to_svg(Handoff.build([%{from: "a&b", to: "c<d", signal: "x>y"}]))
      assert svg =~ "a&amp;b"
      assert svg =~ "c&lt;d"
      assert svg =~ "x&gt;y"
      refute svg =~ "c<d"
    end

    test "handles a self-loop edge" do
      svg = Handoff.to_svg(Handoff.build([%{from: "a", to: "a", signal: "retry"}]))
      assert svg =~ "<svg"
      assert length(Regex.scan(~r/<rect /, svg)) == 1
      assert length(Regex.scan(~r/<path class="edge"/, svg)) == 1
      assert svg =~ ">retry<"
    end

    test "empty graph still yields a valid (empty) svg" do
      svg = Handoff.to_svg(Handoff.build([]))
      assert svg =~ "<svg" and svg =~ "</svg>"
      assert Regex.scan(~r/<rect /, svg) == []
    end
  end
end
