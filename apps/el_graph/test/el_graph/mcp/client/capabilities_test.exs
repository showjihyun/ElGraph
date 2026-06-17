defmodule ElGraph.MCP.Client.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias ElGraph.MCP.Client.Capabilities

  describe "advertise/1" do
    test "advertises only the capabilities whose handlers are provided" do
      caps = Capabilities.advertise(%{sampling: fn _ -> %{} end, roots: fn -> [] end})
      assert %{"sampling" => %{}, "roots" => %{"listChanged" => false}} = caps
      refute Map.has_key?(caps, "elicitation")
    end

    test "empty handlers advertise nothing" do
      assert %{} == Capabilities.advertise(%{})
    end
  end

  describe "handle/3" do
    test "dispatches sampling/createMessage to the sampling handler" do
      handlers = %{sampling: fn params -> %{"role" => "assistant", "content" => params["q"]} end}

      assert {:result, %{"role" => "assistant", "content" => "hi"}} =
               Capabilities.handle("sampling/createMessage", %{"q" => "hi"}, handlers)
    end

    test "dispatches elicitation/create to the elicitation handler" do
      handlers = %{
        elicitation: fn _ -> %{"action" => "accept", "content" => %{"name" => "Ada"}} end
      }

      assert {:result, %{"action" => "accept"}} =
               Capabilities.handle("elicitation/create", %{}, handlers)
    end

    test "dispatches roots/list and wraps the handler's roots" do
      roots = [%{"uri" => "file:///work", "name" => "work"}]
      handlers = %{roots: fn -> roots end}

      assert {:result, %{"roots" => ^roots}} = Capabilities.handle("roots/list", %{}, handlers)
    end

    test "returns method-not-found when the handler is missing" do
      assert {:error, -32601, _} = Capabilities.handle("sampling/createMessage", %{}, %{})
    end

    test "returns method-not-found for an unknown method" do
      assert {:error, -32601, _} = Capabilities.handle("bogus", %{}, %{})
    end
  end
end
