defmodule ElGraph.MCP.ServerResourcesTest do
  use ExUnit.Case, async: true

  alias ElGraph.MCP.Server

  defp deps do
    %{
      tools: [],
      server_info: %{"name" => "elgraph", "version" => "0.2.0"},
      resources: [
        %{
          uri: "el://docs/spec",
          name: "spec",
          description: "the SPEC",
          mime_type: "text/markdown",
          read: fn -> {:ok, "# SPEC"} end
        }
      ],
      prompts: [
        %{
          name: "summarize",
          description: "summarize text",
          arguments: [%{"name" => "text", "required" => true}],
          render: fn args -> [%{role: "user", text: "Summarize: " <> args["text"]}] end
        }
      ]
    }
  end

  test "initialize advertises resources and prompts capabilities when provided" do
    assert {:result, %{"capabilities" => caps}} = Server.handle("initialize", %{}, deps())
    assert %{"tools" => %{}, "resources" => %{}, "prompts" => %{}} = caps
  end

  test "initialize omits resources/prompts capabilities when absent" do
    bare = %{tools: [], server_info: %{"name" => "x", "version" => "0"}}
    assert {:result, %{"capabilities" => caps}} = Server.handle("initialize", %{}, bare)
    refute Map.has_key?(caps, "resources")
    refute Map.has_key?(caps, "prompts")
  end

  describe "resources" do
    test "resources/list returns descriptors with uri/name/mimeType" do
      assert {:result, %{"resources" => [r]}} = Server.handle("resources/list", %{}, deps())
      assert %{"uri" => "el://docs/spec", "name" => "spec", "mimeType" => "text/markdown"} = r
    end

    test "resources/read returns the resource contents" do
      params = %{"uri" => "el://docs/spec"}

      assert {:result, %{"contents" => [content]}} =
               Server.handle("resources/read", params, deps())

      assert %{"uri" => "el://docs/spec", "text" => "# SPEC"} = content
    end

    test "resources/read of an unknown uri is invalid params" do
      assert {:error, -32602, _} =
               Server.handle("resources/read", %{"uri" => "el://nope"}, deps())
    end
  end

  describe "prompts" do
    test "prompts/list returns descriptors with name/arguments" do
      assert {:result, %{"prompts" => [p]}} = Server.handle("prompts/list", %{}, deps())
      assert %{"name" => "summarize", "arguments" => [%{"name" => "text"}]} = p
    end

    test "prompts/get renders messages from the arguments" do
      params = %{"name" => "summarize", "arguments" => %{"text" => "hello"}}
      assert {:result, %{"messages" => [msg]}} = Server.handle("prompts/get", params, deps())

      assert %{"role" => "user", "content" => %{"type" => "text", "text" => "Summarize: hello"}} =
               msg
    end

    test "prompts/get of an unknown prompt is invalid params" do
      assert {:error, -32602, _} =
               Server.handle("prompts/get", %{"name" => "nope", "arguments" => %{}}, deps())
    end
  end
end
