defmodule ElGraph.MCP do
  @moduledoc """
  MCP 서버의 툴을 ElGraph 툴로 변환하는 진입점 (SPEC §4).

      {:ok, tools} = ElGraph.MCP.tools({MyTransport, client})
      specs = Enum.map(tools, &ElGraph.MCP.Tool.to_tool_spec/1)
  """

  alias ElGraph.MCP.Tool

  @doc "클라이언트 `{모듈, 핸들}`에서 툴 목록을 가져와 `ElGraph.MCP.Tool`로 변환한다."
  @spec tools({module(), ElGraph.MCP.Client.client()}) :: {:ok, [Tool.t()]} | {:error, term()}
  def tools({client_mod, client}) do
    with {:ok, tool_defs} <- client_mod.list_tools(client) do
      {:ok, Enum.map(tool_defs, &Tool.from_def(&1, client_mod, client))}
    end
  end
end
