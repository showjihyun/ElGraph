defmodule ElGraph.LLM.GeminiStreamTest do
  use ExUnit.Case, async: true

  alias ElGraph.LLM.Gemini

  # Realistic Gemini streaming chunks (already JSON-decoded maps).
  defp text_chunk(text),
    do: %{"candidates" => [%{"content" => %{"parts" => [%{"text" => text}]}}]}

  describe "decode_deltas/2 — per-chunk delta events" do
    test "yields a token event for a text part" do
      assert {[{:token, "Hello"}], _} =
               Gemini.decode_deltas(text_chunk("Hello"), Gemini.init_stream_state())
    end

    test "synthesizes start/delta/end for a whole functionCall part" do
      chunk = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [%{"functionCall" => %{"name" => "web_search", "args" => %{"q" => "x"}}}]
            }
          }
        ]
      }

      assert {[
                {:tool_call_start, "web_search", "web_search"},
                {:tool_call_delta, "web_search", args_json},
                {:tool_call_end, "web_search"}
              ], _} = Gemini.decode_deltas(chunk, Gemini.init_stream_state())

      assert args_json =~ "x"
    end

    test "yields nothing for a usage-only chunk" do
      assert {[], _} =
               Gemini.decode_deltas(
                 %{"usageMetadata" => %{"promptTokenCount" => 1, "candidatesTokenCount" => 2}},
                 Gemini.init_stream_state()
               )
    end
  end

  describe "decode_usage/1" do
    test "extracts usage from usageMetadata, nil otherwise" do
      assert %{input_tokens: 10, output_tokens: 3} =
               Gemini.decode_usage(%{
                 "usageMetadata" => %{"promptTokenCount" => 10, "candidatesTokenCount" => 3}
               })

      assert nil == Gemini.decode_usage(text_chunk("hi"))
    end
  end

  describe "stream_chat/3 via Req.Test — end-to-end SSE behavior" do
    test "streams text deltas and assembles the final response with usage" do
      sse =
        ~s(data: {"candidates":[{"content":{"parts":[{"text":"Hel"}]}}]}\n\n) <>
          ~s(data: {"candidates":[{"content":{"parts":[{"text":"lo"}]}}]}\n\n) <>
          ~s(data: {"candidates":[{"content":{"parts":[{"text":" world"}]}}],"usageMetadata":{"promptTokenCount":3,"candidatesTokenCount":2}}\n\n)

      Req.Test.stub(GeminiStreamTextStub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse)
      end)

      config = [api_key: "k", req_options: [plug: {Req.Test, GeminiStreamTextStub}]]
      parent = self()

      assert {:ok,
              %{
                message: %{role: :assistant, content: "Hello world", tool_calls: []},
                usage: %{input_tokens: 3, output_tokens: 2}
              }} =
               Gemini.stream_chat(config, [ElGraph.LLM.user("hi")],
                 on_delta: fn d -> send(parent, {:delta, d}) end
               )

      assert_received {:delta, {:token, "Hel"}}
      assert_received {:delta, {:token, "lo"}}
      assert_received {:delta, {:token, " world"}}
    end

    test "streams a functionCall and assembles tool_calls in the final response" do
      sse =
        ~s(data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"web_search","args":{"q":"elixir"}}}]}}]}\n\n) <>
          ~s(data: {"candidates":[{"content":{"parts":[]}}],"usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":4}}\n\n)

      Req.Test.stub(GeminiStreamToolStub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse)
      end)

      config = [api_key: "k", req_options: [plug: {Req.Test, GeminiStreamToolStub}]]
      parent = self()

      assert {:ok,
              %{
                message: %{
                  role: :assistant,
                  content: nil,
                  tool_calls: [%{id: "web_search", name: "web_search", args: %{"q" => "elixir"}}]
                }
              }} =
               Gemini.stream_chat(config, [ElGraph.LLM.user("search")],
                 on_delta: fn d -> send(parent, {:delta, d}) end
               )

      assert_received {:delta, {:tool_call_start, "web_search", "web_search"}}
      assert_received {:delta, {:tool_call_end, "web_search"}}
    end

    test "maps a 500 streaming response to {:api_error, 500, body}" do
      Req.Test.stub(GeminiStream500Stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(500, "boom")
      end)

      config = [api_key: "k", req_options: [plug: {Req.Test, GeminiStream500Stub}]]

      assert {:error, {:api_error, 500, _body}} =
               Gemini.stream_chat(config, [ElGraph.LLM.user("hi")], [])
    end
  end
end
