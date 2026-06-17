defmodule ElGraph.MCP.ServerTest do
  use ExUnit.Case, async: true

  alias ElGraph.MCP.Server
  alias ElGraph.TestActions.{Failing, Search}

  defp deps,
    do: %{tools: [Search, Failing], server_info: %{"name" => "elgraph", "version" => "0.2.0"}}

  describe "initialize" do
    test "returns protocol version, tools capability, and serverInfo" do
      assert {:result, result} = Server.handle("initialize", %{}, deps())
      assert is_binary(result["protocolVersion"])
      assert %{"tools" => %{}} = result["capabilities"]
      assert %{"name" => "elgraph"} = result["serverInfo"]
    end
  end

  describe "tools/list" do
    test "exposes each Action as an MCP tool with a JSON-Schema inputSchema" do
      assert {:result, %{"tools" => tools}} = Server.handle("tools/list", %{}, deps())

      search = Enum.find(tools, &(&1["name"] == "web_search"))
      assert search["description"] == "웹을 검색합니다"
      assert search["inputSchema"]["type"] == "object"
      assert "query" in search["inputSchema"]["required"]
    end
  end

  describe "tools/call" do
    test "executes the action and returns text content with isError false" do
      params = %{"name" => "web_search", "arguments" => %{"query" => "x"}}

      assert {:result, %{"content" => [%{"type" => "text", "text" => text}], "isError" => false}} =
               Server.handle("tools/call", params, deps())

      assert text =~ "r:x:"
    end

    test "surfaces a failing action as isError true (not a protocol error)" do
      params = %{"name" => "fail", "arguments" => %{}}

      assert {:result, %{"isError" => true, "content" => [%{"text" => _}]}} =
               Server.handle("tools/call", params, deps())
    end

    test "surfaces invalid arguments as isError true" do
      # web_search requires :query
      params = %{"name" => "web_search", "arguments" => %{}}
      assert {:result, %{"isError" => true}} = Server.handle("tools/call", params, deps())
    end

    test "an unknown tool is a JSON-RPC invalid-params error" do
      params = %{"name" => "nope", "arguments" => %{}}
      assert {:error, -32602, _msg} = Server.handle("tools/call", params, deps())
    end
  end

  describe "protocol edges" do
    test "an unknown method is method-not-found" do
      assert {:error, -32601, _} = Server.handle("tools/unknown", %{}, deps())
    end

    test "a notification gets no response" do
      assert :notification = Server.handle("notifications/initialized", %{}, deps())
    end
  end
end
