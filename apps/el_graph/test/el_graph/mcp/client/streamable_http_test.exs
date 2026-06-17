defmodule ElGraph.MCP.Client.StreamableHTTPTest do
  use ExUnit.Case, async: true

  alias ElGraph.MCP
  alias ElGraph.MCP.Client.StreamableHTTP

  @url "https://mcp.example/mcp"

  # method로 라우팅하는 MCP 서버 흉내 stub.
  defp server_stub(name) do
    Req.Test.stub(name, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      msg = Jason.decode!(body)
      id = msg["id"]

      result =
        case msg["method"] do
          "initialize" ->
            %{
              "protocolVersion" => "2025-06-18",
              "capabilities" => %{},
              "serverInfo" => %{"name" => "s"}
            }

          "notifications/initialized" ->
            :notification

          "tools/list" ->
            %{
              "tools" => [
                %{"name" => "echo", "description" => "e", "inputSchema" => %{"type" => "object"}}
              ]
            }

          "tools/call" ->
            %{
              "content" => [
                %{"type" => "text", "text" => "got:" <> msg["params"]["arguments"]["x"]}
              ],
              "isError" => false
            }
        end

      case result do
        :notification -> Plug.Conn.send_resp(conn, 202, "")
        r -> Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => r})
      end
    end)
  end

  defp connect(stub) do
    StreamableHTTP.connect(@url, req_options: [plug: {Req.Test, stub}])
  end

  test "connect performs the initialize handshake and captures the protocol version" do
    server_stub(InitStub)
    assert {:ok, handle} = connect(InitStub)
    assert handle.protocol_version == "2025-06-18"
  end

  test "list_tools returns the server's tools" do
    server_stub(ListStub)
    {:ok, handle} = connect(ListStub)
    assert {:ok, [%{"name" => "echo"}]} = StreamableHTTP.list_tools(handle)
  end

  test "call_tool sends name + arguments and returns the MCP result" do
    server_stub(CallStub)
    {:ok, handle} = connect(CallStub)

    assert {:ok, %{"content" => [%{"text" => "got:hi"}], "isError" => false}} =
             StreamableHTTP.call_tool(handle, "echo", %{"x" => "hi"})
  end

  test "works through ElGraph.MCP.tools/1 as a transport adapter" do
    server_stub(AdapterStub)
    {:ok, handle} = connect(AdapterStub)
    assert {:ok, [%ElGraph.MCP.Tool{name: "echo"}]} = MCP.tools({StreamableHTTP, handle})
  end

  test "maps a JSON-RPC error envelope to {:error, ...}" do
    Req.Test.stub(ErrStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      id = Jason.decode!(body)["id"]

      Req.Test.json(conn, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => -32601, "message" => "nope"}
      })
    end)

    handle = %{
      url: @url,
      req_options: [plug: {Req.Test, ErrStub}],
      session_id: nil,
      protocol_version: nil
    }

    assert {:error, {:rpc_error, -32601, "nope"}} = StreamableHTTP.list_tools(handle)
  end
end
