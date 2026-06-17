defmodule ElGraphWeb.MCP.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ElGraphWeb.MCP.Router

  defmodule Echo do
    @moduledoc false
    use ElGraph.Action,
      name: "echo",
      description: "echoes text",
      schema: [text: [type: :string, required: true]]

    @impl true
    def run(%{text: t}, _ctx), do: {:ok, %{echoed: t}}
  end

  defp call(body) do
    conn(:post, "/", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> assign(:mcp_tools, [Echo])
    |> assign(:mcp_server_info, %{"name" => "test", "version" => "0"})
    |> Router.call(Router.init([]))
  end

  test "initialize returns a JSON-RPC result envelope" do
    conn = call(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}})
    assert conn.status == 200

    assert %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"protocolVersion" => _}} =
             Jason.decode!(conn.resp_body)
  end

  test "tools/list lists the injected Action" do
    conn = call(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list", "params" => %{}})
    assert %{"result" => %{"tools" => [%{"name" => "echo"}]}} = Jason.decode!(conn.resp_body)
  end

  test "tools/call executes the tool and returns content" do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 3,
      "method" => "tools/call",
      "params" => %{"name" => "echo", "arguments" => %{"text" => "hi"}}
    }

    conn = call(body)

    assert %{"result" => %{"isError" => false, "content" => [%{"text" => text}]}} =
             Jason.decode!(conn.resp_body)

    assert text =~ "hi"
  end

  test "an unknown method returns a JSON-RPC error envelope (HTTP 200)" do
    conn = call(%{"jsonrpc" => "2.0", "id" => 4, "method" => "bogus", "params" => %{}})
    assert conn.status == 200
    assert %{"id" => 4, "error" => %{"code" => -32601}} = Jason.decode!(conn.resp_body)
  end

  test "a notification gets 202 with an empty body" do
    conn = call(%{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}})
    assert conn.status == 202
    assert conn.resp_body == ""
  end
end
