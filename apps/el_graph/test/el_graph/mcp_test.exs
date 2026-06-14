defmodule ElGraph.MCPTest do
  use ExUnit.Case, async: true

  alias ElGraph.{FakeMCPClient, MCP}
  alias ElGraph.MCP.Tool

  @tool_defs [
    %{
      "name" => "get_weather",
      "description" => "날씨를 조회합니다",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"city" => %{"type" => "string"}},
        "required" => ["city"]
      }
    }
  ]

  defp client(extra \\ %{}), do: {FakeMCPClient, Map.merge(%{tools: @tool_defs}, extra)}

  describe "tools/1 (SPEC §4: MCP 툴 → 자동 변환)" do
    test "converts MCP tool definitions into Tool structs" do
      assert {:ok, [%Tool{name: "get_weather", description: "날씨를 조회합니다"} = tool]} =
               MCP.tools(client())

      assert %{"type" => "object", "properties" => %{"city" => _}} = tool.input_schema
    end

    test "propagates client errors" do
      assert {:error, :connection_refused} = MCP.tools({FakeMCPClient, :fail})
    end
  end

  describe "Tool" do
    test "to_tool_spec/1 matches the Action tool-spec shape" do
      {:ok, [tool]} = MCP.tools(client())

      assert %{
               name: "get_weather",
               description: "날씨를 조회합니다",
               input_schema: %{"type" => "object"}
             } = Tool.to_tool_spec(tool)
    end

    test "execute/3 calls the tool through the client" do
      {:ok, [tool]} = MCP.tools(client(%{owner: self()}))

      assert {:ok, %{"echoed" => %{"city" => "Seoul"}}} =
               Tool.execute(tool, %{"city" => "Seoul"}, %{})

      assert_receive {:mcp_call, "get_weather", %{"city" => "Seoul"}}
    end
  end
end
