defmodule ElGraphWeb.AuthTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ElGraphWeb.Router
  alias ElGraphWeb.TestAgent

  defp call(conn, api_keys) do
    conn
    |> assign(:agents, TestAgent.registry())
    |> assign(:api_keys, api_keys)
    |> Router.call(Router.init([]))
  end

  test "no Authorization header → 401" do
    conn = call(conn(:get, "/a2a/echo/agent-card"), ["secret"])
    assert conn.status == 401
    assert %{"error" => "unauthorized"} = Jason.decode!(conn.resp_body)
  end

  test "wrong key → 401" do
    conn =
      conn(:get, "/a2a/echo/agent-card")
      |> put_req_header("authorization", "Bearer nope")
      |> call(["secret"])

    assert conn.status == 401
  end

  test "correct Bearer key → reaches the route (200)" do
    conn =
      conn(:get, "/a2a/echo/agent-card")
      |> put_req_header("authorization", "Bearer secret")
      |> call(["secret"])

    assert conn.status == 200
    assert %{"name" => "echo"} = Jason.decode!(conn.resp_body)
  end

  test "x-api-key header → 200" do
    conn =
      conn(:get, "/a2a/echo/agent-card")
      |> put_req_header("x-api-key", "secret")
      |> call(["secret"])

    assert conn.status == 200
  end

  test "api_keys = [] → 401 (fail-closed, no explicit keys)" do
    conn = call(conn(:get, "/a2a/echo/agent-card"), [])
    assert conn.status == 401
    assert %{"error" => "unauthorized"} = Jason.decode!(conn.resp_body)
  end

  test "api_keys = nil → 401 (fail-closed)" do
    conn = call(conn(:get, "/a2a/echo/agent-card"), nil)
    assert conn.status == 401
  end

  test "api_keys = :public → open (200 without header)" do
    conn = call(conn(:get, "/a2a/echo/agent-card"), :public)
    assert conn.status == 200
    assert %{"name" => "echo"} = Jason.decode!(conn.resp_body)
  end
end
