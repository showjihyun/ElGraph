defmodule ElGraphWeb.IntegrationTest do
  # Live Bandit server on localhost — hermetic but not async (binds a real port).
  use ExUnit.Case, async: false

  alias ElGraphWeb.TaskStore
  alias ElGraphWeb.TestAgent

  @port 41_877
  @base "http://127.0.0.1:#{@port}"

  setup do
    start_supervised!(TaskStore, id: :integration_task_store)

    start_supervised!(
      ElGraphWeb.server_spec(
        agents: TestAgent.registry(),
        port: @port,
        task_store: ElGraphWeb.TaskStore,
        # 인증 없는 라우팅 라운드트립을 검증하는 테스트 — fail-closed 기본값을 명시적으로 끈다.
        api_keys: :public
      )
    )

    :ok
  end

  defp rpc(method, params, id) do
    Req.post!("#{@base}/a2a/echo",
      json: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    )
  end

  test "message/send → tasks/get round-trip over real HTTP" do
    send_resp =
      rpc("message/send", %{"message" => %{"role" => "user", "parts" => [%{"text" => "hi"}]}}, 1)

    assert send_resp.status == 200
    assert %{"jsonrpc" => "2.0", "id" => 1, "result" => task} = send_resp.body
    assert %{"id" => id, "status" => %{"state" => "completed"}} = task
    assert is_binary(id)

    get_resp = rpc("tasks/get", %{"id" => id}, 2)
    assert %{"result" => %{"id" => ^id, "status" => %{"state" => "completed"}}} = get_resp.body
  end

  test "unknown method → JSON-RPC -32601" do
    resp = rpc("nope/method", %{}, 9)
    assert %{"error" => %{"code" => -32601}} = resp.body
  end

  test "GET well-known agent card" do
    resp = Req.get!("#{@base}/a2a/echo/.well-known/agent-card.json")
    assert resp.status == 200
    assert %{"name" => "echo", "capabilities" => %{"streaming" => true}} = resp.body
  end
end
