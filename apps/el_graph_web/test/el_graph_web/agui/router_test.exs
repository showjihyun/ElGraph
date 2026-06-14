defmodule ElGraphWeb.AGUI.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ElGraphWeb.AGUI.Router
  alias ElGraphWeb.TestAgent

  defp call(conn) do
    conn
    |> assign(:agents, TestAgent.registry())
    |> Router.call(Router.init([]))
  end

  describe "POST /:name/run" do
    test "streams AG-UI events as SSE" do
      body = Jason.encode!(%{"question" => "hi"})

      conn =
        conn(:post, "/echo/run", body)
        |> put_req_header("content-type", "application/json")
        |> call()

      assert conn.status == 200
      assert conn.state == :chunked
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/event-stream"

      frames = parse_sse(conn.resp_body)
      types = Enum.map(frames, & &1["type"])

      assert "RUN_STARTED" == hd(types)
      assert "RUN_FINISHED" == List.last(types)
      assert "TEXT_MESSAGE_CONTENT" in types
      # the streamed token reached the client
      assert Enum.any?(
               frames,
               &(&1["type"] == "TEXT_MESSAGE_CONTENT" and &1["delta"] =~ "echo: hi")
             )
    end

    test "404 for an unknown agent" do
      body = Jason.encode!(%{"question" => "hi"})

      conn =
        conn(:post, "/nope/run", body)
        |> put_req_header("content-type", "application/json")
        |> call()

      assert conn.status == 404
    end
  end

  # "data: {json}\n\n" 프레임들을 디코드한다.
  defp parse_sse(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn "data: " <> json -> Jason.decode!(json) end)
  end
end
