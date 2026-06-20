defmodule ElGraph.LLM.AnthropicStreamTest do
  use ExUnit.Case, async: true

  alias ElGraph.LLM.Anthropic

  # Realistic Anthropic streaming chunks (already JSON-decoded maps).
  defp text_delta(text),
    do: %{
      "type" => "content_block_delta",
      "index" => 0,
      "delta" => %{"type" => "text_delta", "text" => text}
    }

  # Fold chunks through decode_deltas/2, threading state, collecting deltas in order.
  defp decode_all(chunks) do
    {deltas, _state} =
      Enum.reduce(chunks, {[], Anthropic.init_stream_state()}, fn chunk, {acc, st} ->
        {ds, st} = Anthropic.decode_deltas(chunk, st)
        {acc ++ ds, st}
      end)

    deltas
  end

  describe "decode_deltas/2 — per-chunk delta events (stateful)" do
    test "yields a token event for a text delta" do
      assert {[{:token, "Hello"}], _} =
               Anthropic.decode_deltas(text_delta("Hello"), Anthropic.init_stream_state())
    end

    test "yields nothing for message_start / message_delta usage chunks" do
      assert {[], _} =
               Anthropic.decode_deltas(
                 %{"type" => "message_start", "message" => %{"usage" => %{"input_tokens" => 10}}},
                 Anthropic.init_stream_state()
               )

      assert {[], _} =
               Anthropic.decode_deltas(
                 %{"type" => "message_delta", "delta" => %{}, "usage" => %{"output_tokens" => 5}},
                 Anthropic.init_stream_state()
               )
    end

    test "emits tool_call_start/delta/end across chunks (threading index→id)" do
      chunks = [
        %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{"type" => "tool_use", "id" => "toolu_1", "name" => "web_search"}
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"q\":"}
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "input_json_delta", "partial_json" => "\"x\"}"}
        },
        %{"type" => "content_block_stop", "index" => 0}
      ]

      assert [
               {:tool_call_start, "toolu_1", "web_search"},
               {:tool_call_delta, "toolu_1", "{\"q\":"},
               {:tool_call_delta, "toolu_1", "\"x\"}"},
               {:tool_call_end, "toolu_1"}
             ] = decode_all(chunks)
    end
  end

  describe "decode_usage/1" do
    test "extracts input from message_start, output from message_delta, nil otherwise" do
      assert %{input_tokens: 10} =
               Anthropic.decode_usage(%{
                 "type" => "message_start",
                 "message" => %{"usage" => %{"input_tokens" => 10}}
               })

      assert %{output_tokens: 5} =
               Anthropic.decode_usage(%{
                 "type" => "message_delta",
                 "usage" => %{"output_tokens" => 5}
               })

      assert nil == Anthropic.decode_usage(text_delta("hi"))
    end
  end

  describe "stream_chat/3 via Req.Test — end-to-end SSE behavior" do
    test "streams text deltas and assembles the final response with usage" do
      sse =
        ~s(event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":3}}}\n\n) <>
          ~s(event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}\n\n) <>
          ~s(event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}\n\n) <>
          ~s(event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}\n\n) <>
          ~s(event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}\n\n) <>
          ~s(event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n) <>
          ~s(event: message_delta\ndata: {"type":"message_delta","delta":{},"usage":{"output_tokens":2}}\n\n) <>
          ~s(event: message_stop\ndata: {"type":"message_stop"}\n\n)

      Req.Test.stub(AnthropicStreamTextStub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse)
      end)

      config = [api_key: "k", req_options: [plug: {Req.Test, AnthropicStreamTextStub}]]
      parent = self()

      assert {:ok,
              %{
                message: %{role: :assistant, content: "Hello world", tool_calls: []},
                usage: %{input_tokens: 3, output_tokens: 2}
              }} =
               Anthropic.stream_chat(config, [ElGraph.LLM.user("hi")],
                 on_delta: fn d -> send(parent, {:delta, d}) end
               )

      assert_received {:delta, {:token, "Hel"}}
      assert_received {:delta, {:token, "lo"}}
      assert_received {:delta, {:token, " world"}}
    end

    test "streams a tool call and assembles tool_calls in the final response" do
      sse =
        ~s(event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":7}}}\n\n) <>
          ~s(event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"web_search"}}\n\n) <>
          ~s(event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"q\\":"}}\n\n) <>
          ~s(event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\\"elixir\\"}"}}\n\n) <>
          ~s(event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n) <>
          ~s(event: message_delta\ndata: {"type":"message_delta","delta":{},"usage":{"output_tokens":4}}\n\n) <>
          ~s(event: message_stop\ndata: {"type":"message_stop"}\n\n)

      Req.Test.stub(AnthropicStreamToolStub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse)
      end)

      config = [api_key: "k", req_options: [plug: {Req.Test, AnthropicStreamToolStub}]]
      parent = self()

      assert {:ok,
              %{
                message: %{
                  role: :assistant,
                  content: nil,
                  tool_calls: [%{id: "toolu_1", name: "web_search", args: %{"q" => "elixir"}}]
                }
              }} =
               Anthropic.stream_chat(config, [ElGraph.LLM.user("search")],
                 on_delta: fn d -> send(parent, {:delta, d}) end
               )

      assert_received {:delta, {:tool_call_start, "toolu_1", "web_search"}}
      assert_received {:delta, {:tool_call_end, "toolu_1"}}
    end

    test "maps a 500 streaming response to {:api_error, 500, body}" do
      Req.Test.stub(AnthropicStream500Stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(500, "boom")
      end)

      config = [api_key: "k", req_options: [plug: {Req.Test, AnthropicStream500Stub}]]

      assert {:error, {:api_error, 500, _body}} =
               Anthropic.stream_chat(config, [ElGraph.LLM.user("hi")], [])
    end
  end
end
