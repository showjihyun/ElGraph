defmodule ElGraphWeb.MCP.LoopbackTest do
  # 종단 검증: StreamableHTTP 클라이언트 → 실제 MCP.Router → MCP.Server → Action.
  # Req의 :plug를 실제 Router로 두어 포트 없이 in-process로 전체 스택을 통과시킨다.
  use ExUnit.Case, async: true

  alias ElGraph.MCP
  alias ElGraph.MCP.Client.StreamableHTTP
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

  defp connect do
    router = fn conn ->
      conn
      |> Plug.Conn.assign(:mcp_tools, [Echo])
      |> Router.call(Router.init([]))
    end

    # MCP.Router를 직접 plug로 호출 — 상위 forward("/mcp")가 접두를 벗긴 것과 동일하게 "/"로 친다.
    StreamableHTTP.connect("http://mcp.local/", req_options: [plug: router])
  end

  test "connect + list + call flow end-to-end through the real Router" do
    assert {:ok, handle} = connect()
    assert handle.protocol_version == "2025-06-18"

    assert {:ok, [%MCP.Tool{name: "echo"} = tool]} = MCP.tools({StreamableHTTP, handle})

    assert {:ok, %{"content" => [%{"text" => text}], "isError" => false}} =
             MCP.Tool.execute(tool, %{"text" => "hi"}, %{})

    assert text =~ "hi"
  end
end
