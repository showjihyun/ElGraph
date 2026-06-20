defmodule ElGraphWeb.A2A.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ElGraphWeb.A2A.Router
  alias ElGraphWeb.TaskStore
  alias ElGraphWeb.TestAgent

  defp call(conn) do
    conn
    |> assign(:agents, TestAgent.registry())
    |> Router.call(Router.init([]))
  end

  defp call_rpc(conn, store) do
    conn
    |> assign(:agents, TestAgent.registry())
    |> assign(:task_store, store)
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

  describe "request body size limit (fail-closed)" do
    test "a body over the 1 MB cap is rejected before reaching the graph" do
      big =
        Jason.encode!(%{
          "role" => "user",
          "parts" => [%{"text" => String.duplicate("x", 1_000_001)}]
        })

      assert_raise Plug.Parsers.RequestTooLargeError, fn ->
        conn(:post, "/echo/message", big)
        |> put_req_header("content-type", "application/json")
        |> call()
      end
    end
  end

  describe "GET /:name/.well-known/agent-card.json" do
    test "returns the A2A Agent Card as JSON" do
      conn = call(conn(:get, "/echo/.well-known/agent-card.json"))

      assert conn.status == 200
      assert %{"name" => "echo"} = Jason.decode!(conn.resp_body)
    end
  end

  describe "POST /:name (JSON-RPC 2.0)" do
    setup do
      # async 테스트 간 이름 충돌 방지 — 테스트별 고유 이름으로 격리.
      name = :"task_store_#{System.unique_integer([:positive])}"
      %{store: start_supervised!({TaskStore, name: name})}
    end

    defp rpc_body(method, params, id) do
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
    end

    defp post_rpc(store, method, params, id \\ 1) do
      conn(:post, "/echo", rpc_body(method, params, id))
      |> put_req_header("content-type", "application/json")
      |> call_rpc(store)
    end

    test "message/send returns a completed Task in a JSON-RPC envelope", %{store: store} do
      params = %{"message" => %{"role" => "user", "parts" => [%{"text" => "hello"}]}}
      conn = post_rpc(store, "message/send", params)

      assert conn.status == 200

      assert %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "result" => %{"id" => id, "status" => %{"state" => "completed"}}
             } = Jason.decode!(conn.resp_body)

      assert is_binary(id)
    end

    test "tasks/get returns a previously stored Task", %{store: store} do
      params = %{"message" => %{"role" => "user", "parts" => [%{"text" => "hi"}]}}

      %{"result" => %{"id" => id}} =
        Jason.decode!(post_rpc(store, "message/send", params).resp_body)

      conn = post_rpc(store, "tasks/get", %{"id" => id}, 2)

      assert %{"id" => 2, "result" => %{"id" => ^id}} = Jason.decode!(conn.resp_body)
    end

    test "tasks/get unknown id → error -32001", %{store: store} do
      conn = post_rpc(store, "tasks/get", %{"id" => "nope"}, 3)
      assert %{"error" => %{"code" => -32001}} = Jason.decode!(conn.resp_body)
    end

    test "unknown method → error -32601", %{store: store} do
      conn = post_rpc(store, "bogus", %{}, 4)
      assert %{"error" => %{"code" => -32601}} = Jason.decode!(conn.resp_body)
    end

    test "missing method → error -32600 Invalid Request", %{store: store} do
      conn =
        conn(:post, "/echo", Jason.encode!(%{"jsonrpc" => "2.0", "id" => 5}))
        |> put_req_header("content-type", "application/json")
        |> call_rpc(store)

      assert %{"error" => %{"code" => -32600}} = Jason.decode!(conn.resp_body)
    end

    test "message/stream returns an SSE event stream", %{store: store} do
      params = %{"message" => %{"role" => "user", "parts" => [%{"text" => "yo"}]}}
      conn = post_rpc(store, "message/stream", params)

      assert conn.status == 200
      assert conn.state == :chunked
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/event-stream"

      frames =
        conn.resp_body
        |> String.split("\n\n", trim: true)
        |> Enum.map(fn "data: " <> json -> Jason.decode!(json) end)

      assert List.last(frames)["result"]["status"]["state"] == "completed"
    end
  end
end
