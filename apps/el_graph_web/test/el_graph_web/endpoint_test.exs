defmodule ElGraphWeb.EndpointTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias ElGraphWeb.Endpoint
  alias ElGraphWeb.TestAgent

  defp call(conn), do: Endpoint.call(conn, Endpoint.init(agents: TestAgent.registry()))

  test "injects agents and forwards /a2a to the A2A router" do
    conn = call(conn(:get, "/a2a/echo/agent-card"))
    assert conn.status == 200
    assert %{"name" => "echo"} = Jason.decode!(conn.resp_body)
  end

  test "forwards /agui to the AG-UI router" do
    body = Jason.encode!(%{"question" => "hi"})

    conn =
      conn(:post, "/agui/echo/run", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> call()

    assert conn.status == 200
    assert conn.state == :chunked
  end

  test "404 for an unknown path" do
    conn = call(conn(:get, "/nope"))
    assert conn.status == 404
  end
end
