defmodule ElGraph.FakeMCPClient do
  @moduledoc false
  @behaviour ElGraph.MCP.Client

  @impl true
  def list_tools(:fail), do: {:error, :connection_refused}
  def list_tools(%{tools: tools}), do: {:ok, tools}

  @impl true
  def call_tool(%{owner: owner}, name, args) do
    send(owner, {:mcp_call, name, args})
    {:ok, %{"echoed" => args}}
  end
end
