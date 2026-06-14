defmodule ElGraph.TestAgent do
  @moduledoc false
  use ElGraph.Agent

  alias ElGraph.Signal

  @impl true
  def handle_signal(%Signal{type: "ignore" <> _rest}, _context), do: :ignore
  def handle_signal(%Signal{data: data}, _context), do: {:run, data || %{}}

  @impl true
  def handle_result(result, context) do
    if owner = context.opts[:owner], do: send(owner, {:agent_result, context.id, result})
    :ok
  end
end
