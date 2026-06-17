defmodule ElGraph.MCP.Client.ReceiverTest do
  use ExUnit.Case, async: true

  alias ElGraph.MCP.Client.Receiver

  defp handlers do
    %{
      sampling: fn params -> %{"role" => "assistant", "content" => params["prompt"]} end,
      roots: fn -> [%{"uri" => "file:///w", "name" => "w"}] end
    }
  end

  defp req(id, method, params),
    do: Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

  describe "handle_message/2" do
    test "answers a server-initiated request via the matching capability handler" do
      json = req(7, "sampling/createMessage", %{"prompt" => "hi"})
      assert {:respond, response} = Receiver.handle_message(json, handlers())

      assert %{"jsonrpc" => "2.0", "id" => 7, "result" => %{"content" => "hi"}} =
               Jason.decode!(response)
    end

    test "answers an unsupported method with a JSON-RPC error envelope" do
      json = req(8, "elicitation/create", %{})
      assert {:respond, response} = Receiver.handle_message(json, handlers())
      assert %{"id" => 8, "error" => %{"code" => -32601}} = Jason.decode!(response)
    end

    test "ignores a notification (no id)" do
      json = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/x", "params" => %{}})
      assert :ignore = Receiver.handle_message(json, handlers())
    end

    test "ignores invalid JSON" do
      assert :ignore = Receiver.handle_message("garbage", handlers())
    end
  end

  describe "run/3 over an SSE chunk stream" do
    test "parses events across chunk boundaries and responds to each request" do
      parent = self()
      respond = fn json -> send(parent, {:sent, Jason.decode!(json)}) end

      # 두 요청을 SSE 이벤트로, 청크 경계를 일부러 이벤트 중간에 둔다.
      e1 = "data: " <> req(1, "roots/list", %{}) <> "\n\n"
      e2 = "data: " <> req(2, "sampling/createMessage", %{"prompt" => "yo"}) <> "\n\n"
      {head, tail} = String.split_at(e1 <> e2, 30)

      assert :ok = Receiver.run([head, tail], handlers(), respond)

      assert_received {:sent, %{"id" => 1, "result" => %{"roots" => [_ | _]}}}
      assert_received {:sent, %{"id" => 2, "result" => %{"content" => "yo"}}}
    end
  end
end
