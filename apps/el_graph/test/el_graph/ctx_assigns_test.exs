defmodule ElGraph.CtxAssignsTest do
  use ExUnit.Case, async: true

  defmodule Nodes do
    @moduledoc false
    # Remote-capture node fn: reads the per-invocation, read-only ctx.assigns.
    def probe(_state, ctx), do: %{seen: ctx.assigns[:probe]}
  end

  defp probe_graph do
    ElGraph.new()
    |> ElGraph.state(:seen)
    |> ElGraph.add_node(:probe, &Nodes.probe/2)
    |> ElGraph.add_edge(:probe, :end)
    |> ElGraph.compile(entry: :probe)
  end

  test "ctx.assigns carries the map passed to invoke/3 assigns option" do
    assert {:ok, %{seen: "X"}} =
             ElGraph.invoke(probe_graph(), %{}, assigns: %{probe: "X"})
  end

  test "ctx.assigns defaults to %{} when invoke is called without assigns" do
    assert {:ok, %{seen: nil}} = ElGraph.invoke(probe_graph(), %{})
  end
end
