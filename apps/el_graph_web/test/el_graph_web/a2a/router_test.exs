defmodule ElGraphWeb.A2A.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ElGraphWeb.A2A.Router
  alias ElGraphWeb.TestAgent

  defp call(conn) do
    conn
    |> assign(:agents, TestAgent.registry())
    |> Router.call(Router.init([]))
  end

  describe "GET /:name/agent-card" do
    test "returns the A2A Agent Card as JSON" do
      conn = call(conn(:get, "/echo/agent-card"))

      assert conn.status == 200

      assert %{"name" => "echo", "capabilities" => %{"streaming" => true}} =
               Jason.decode!(conn.resp_body)
    end

    test "404 for an unknown agent" do
      conn = call(conn(:get, "/nope/agent-card"))
      assert conn.status == 404
    end
  end

  describe "POST /:name/message" do
    test "runs the graph and returns a COMPLETED task state" do
      body = Jason.encode!(%{"role" => "user", "parts" => [%{"text" => "hello"}]})

      conn =
        conn(:post, "/echo/message", body)
        |> put_req_header("content-type", "application/json")
        |> call()

      assert conn.status == 200

      assert %{"state" => "completed", "result" => %{"answer" => "echo: hello"}} =
               Jason.decode!(conn.resp_body)
    end

    test "404 for an unknown agent" do
      body = Jason.encode!(%{"role" => "user", "parts" => [%{"text" => "x"}]})

      conn =
        conn(:post, "/nope/message", body)
        |> put_req_header("content-type", "application/json")
        |> call()

      assert conn.status == 404
    end
  end
end
