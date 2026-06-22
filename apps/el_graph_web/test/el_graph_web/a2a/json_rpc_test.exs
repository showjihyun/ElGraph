defmodule ElGraphWeb.A2A.JSONRPCTest do
  use ExUnit.Case, async: true

  alias ElGraphWeb.A2A.JSONRPC
  alias ElGraphWeb.TaskStore
  alias ElGraphWeb.TestAgent

  setup do
    store = start_supervised!({TaskStore, name: nil})
    spec = TestAgent.registry()["echo"]
    %{deps: %{graph: spec.graph, task_store: store}}
  end

  defp message(text), do: %{"message" => %{"role" => "user", "parts" => [%{"text" => text}]}}

  describe "message/send" do
    test "runs the graph, stores and returns an A2A Task", %{deps: deps} do
      assert {:result, task} = JSONRPC.handle("message/send", message("hello"), deps)

      assert %{
               "id" => id,
               "contextId" => _ctx,
               "status" => %{"state" => "completed"},
               "artifacts" => [%{"parts" => [%{"text" => text}]}],
               "history" => _
             } = task

      assert is_binary(id)
      assert text =~ "echo: hello"
    end

    test "stored task is retrievable via tasks/get", %{deps: deps} do
      {:result, %{"id" => id}} = JSONRPC.handle("message/send", message("hi"), deps)

      assert {:result, %{"id" => ^id, "status" => %{"state" => "completed"}}} =
               JSONRPC.handle("tasks/get", %{"id" => id}, deps)
    end
  end

  describe "tasks/get" do
    test "unknown id → -32001 Task not found", %{deps: deps} do
      assert {:error, -32001, _msg} = JSONRPC.handle("tasks/get", %{"id" => "nope"}, deps)
    end

    test "a task is not retrievable by a different caller (no IDOR)", %{deps: deps} do
      deps_a = Map.put(deps, :caller, "caller-a")
      deps_b = Map.put(deps, :caller, "caller-b")

      {:result, %{"id" => id}} = JSONRPC.handle("message/send", message("hi"), deps_a)

      assert {:result, %{"id" => ^id}} = JSONRPC.handle("tasks/get", %{"id" => id}, deps_a)
      assert {:error, -32001, _} = JSONRPC.handle("tasks/get", %{"id" => id}, deps_b)
    end
  end

  describe "errors" do
    test "unknown method → -32601", %{deps: deps} do
      assert {:error, -32601, _msg} = JSONRPC.handle("bogus/method", %{}, deps)
    end
  end

  describe "message/stream" do
    test "returns a stream of JSON-RPC result frames ending in completed", %{deps: deps} do
      assert {:stream, enum} = JSONRPC.handle("message/stream", message("yo"), deps)

      frames = Enum.to_list(enum)
      kinds = Enum.map(frames, & &1["result"]["kind"])

      assert "status-update" in kinds
      assert List.last(frames)["result"]["status"]["state"] == "completed"
      assert Enum.all?(frames, &(&1["jsonrpc"] == "2.0"))
    end
  end
end
