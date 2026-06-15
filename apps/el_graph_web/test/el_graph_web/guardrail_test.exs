defmodule ElGraphWeb.GuardrailTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ElGraph.Guardrail
  alias ElGraphWeb.AGUI
  alias ElGraphWeb.A2A
  alias ElGraphWeb.TaskStore
  alias ElGraphWeb.TestAgent

  defp deny_secret, do: [Guardrail.deny(~r/secret/, :secret)]

  defp a2a_rpc(conn, store, guardrails) do
    conn
    |> assign(:agents, TestAgent.registry())
    |> assign(:task_store, store)
    |> assign(:guardrails, guardrails)
    |> A2A.Router.call(A2A.Router.init([]))
  end

  defp agui_call(conn, guardrails) do
    conn
    |> assign(:agents, TestAgent.registry())
    |> assign(:guardrails, guardrails)
    |> AGUI.Router.call(AGUI.Router.init([]))
  end

  defp rpc_body(method, params) do
    Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
  end

  describe "A2A message/send" do
    setup do
      %{store: start_supervised!({TaskStore, name: nil}, id: :guardrail_task_store)}
    end

    test "denied text → JSON-RPC error -32602, graph NOT invoked", %{store: store} do
      params = %{"message" => %{"role" => "user", "parts" => [%{"text" => "the secret"}]}}

      conn =
        conn(:post, "/echo", rpc_body("message/send", params))
        |> put_req_header("content-type", "application/json")
        |> a2a_rpc(store, deny_secret())

      assert conn.status == 200
      assert %{"error" => %{"code" => -32602}} = Jason.decode!(conn.resp_body)
      # graph not invoked → nothing stored
      assert :error = TaskStore.get(store, "any")
    end

    test "clean text → proceeds (200)", %{store: store} do
      params = %{"message" => %{"role" => "user", "parts" => [%{"text" => "hello"}]}}

      conn =
        conn(:post, "/echo", rpc_body("message/send", params))
        |> put_req_header("content-type", "application/json")
        |> a2a_rpc(store, deny_secret())

      assert conn.status == 200

      assert %{"result" => %{"status" => %{"state" => "completed"}}} =
               Jason.decode!(conn.resp_body)
    end

    test "guardrails = [] → proceeds even with secret", %{store: store} do
      params = %{"message" => %{"role" => "user", "parts" => [%{"text" => "the secret"}]}}

      conn =
        conn(:post, "/echo", rpc_body("message/send", params))
        |> put_req_header("content-type", "application/json")
        |> a2a_rpc(store, [])

      assert conn.status == 200

      assert %{"result" => %{"status" => %{"state" => "completed"}}} =
               Jason.decode!(conn.resp_body)
    end
  end

  describe "A2A POST /:name/message (REST)" do
    test "denied text → 403" do
      body = Jason.encode!(%{"role" => "user", "parts" => [%{"text" => "the secret"}]})

      conn =
        conn(:post, "/echo/message", body)
        |> put_req_header("content-type", "application/json")
        |> a2a_rpc(nil, deny_secret())

      assert conn.status == 403
      assert %{"error" => "guardrail_blocked"} = Jason.decode!(conn.resp_body)
    end

    test "clean text → 200" do
      body = Jason.encode!(%{"role" => "user", "parts" => [%{"text" => "hello"}]})

      conn =
        conn(:post, "/echo/message", body)
        |> put_req_header("content-type", "application/json")
        |> a2a_rpc(nil, deny_secret())

      assert conn.status == 200
    end
  end

  describe "AGUI run" do
    test "denied text → 403" do
      body = Jason.encode!(%{"question" => "the secret"})

      conn =
        conn(:post, "/echo/run", body)
        |> put_req_header("content-type", "application/json")
        |> agui_call(deny_secret())

      assert conn.status == 403
      assert %{"error" => "guardrail_blocked"} = Jason.decode!(conn.resp_body)
    end

    test "clean text → proceeds (chunked)" do
      body = Jason.encode!(%{"question" => "hi"})

      conn =
        conn(:post, "/echo/run", body)
        |> put_req_header("content-type", "application/json")
        |> agui_call(deny_secret())

      assert conn.status == 200
      assert conn.state == :chunked
    end

    test "guardrails = [] → proceeds" do
      body = Jason.encode!(%{"question" => "the secret"})

      conn =
        conn(:post, "/echo/run", body)
        |> put_req_header("content-type", "application/json")
        |> agui_call([])

      assert conn.status == 200
      assert conn.state == :chunked
    end
  end
end
