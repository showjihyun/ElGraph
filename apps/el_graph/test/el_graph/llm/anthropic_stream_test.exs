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

  describe "decode_deltas/1 — per-chunk delta events" do
    test "yields a token event for a text delta" do
      assert [{:token, "Hello"}] = Anthropic.decode_deltas(text_delta("Hello"))
    end

    test "yields nothing for a tool input_json delta" do
      assert [] =
               Anthropic.decode_deltas(%{
                 "type" => "content_block_delta",
                 "index" => 1,
                 "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"q"}
               })
    end

    test "yields nothing for a message_start chunk" do
      assert [] =
               Anthropic.decode_deltas(%{
                 "type" => "message_start",
                 "message" => %{"usage" => %{"input_tokens" => 10}}
               })
    end

    test "yields nothing for a message_delta usage chunk" do
      assert [] =
               Anthropic.decode_deltas(%{
                 "type" => "message_delta",
                 "delta" => %{},
                 "usage" => %{"output_tokens" => 5}
               })
    end
  end

  describe "stream_step/3 — incremental tool-call deltas" do
    test "emits tool_call_start/delta/end across chunks" do
      parent = self()
      on_delta = fn d -> send(parent, {:d, d}) end

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

      Enum.reduce(chunks, Anthropic.new_stream_acc(), &Anthropic.stream_step(&1, &2, on_delta))

      assert_received {:d, {:tool_call_start, "toolu_1", "web_search"}}
      assert_received {:d, {:tool_call_delta, "toolu_1", "{\"q\":"}}
      assert_received {:d, {:tool_call_delta, "toolu_1", "\"x\"}"}}
      assert_received {:d, {:tool_call_end, "toolu_1"}}
    end

    test "emits a token for a text delta" do
      parent = self()

      Anthropic.stream_step(text_delta("hi"), Anthropic.new_stream_acc(), fn d ->
        send(parent, {:d, d})
      end)

      assert_received {:d, {:token, "hi"}}
    end
  end

  describe "reduce_chunks/1 — assemble final response" do
    test "concatenates text deltas into the assistant message" do
      chunks = [
        %{"type" => "message_start", "message" => %{"usage" => %{"input_tokens" => 10}}},
        %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text"}},
        text_delta("Hel"),
        text_delta("lo"),
        text_delta(" world"),
        %{"type" => "content_block_stop", "index" => 0},
        %{"type" => "message_delta", "delta" => %{}, "usage" => %{"output_tokens" => 3}},
        %{"type" => "message_stop"}
      ]

      assert {:ok, %{message: %{role: :assistant, content: "Hello world", tool_calls: []}}} =
               Anthropic.reduce_chunks(chunks)
    end

    test "captures usage from message_start and message_delta" do
      chunks = [
        %{"type" => "message_start", "message" => %{"usage" => %{"input_tokens" => 10}}},
        text_delta("hi"),
        %{"type" => "message_delta", "delta" => %{}, "usage" => %{"output_tokens" => 3}}
      ]

      assert {:ok, %{usage: %{input_tokens: 10, output_tokens: 3}}} =
               Anthropic.reduce_chunks(chunks)
    end

    test "nil content with accumulated tool_calls when only a tool call streams" do
      chunks = [
        %{"type" => "message_start", "message" => %{"usage" => %{"input_tokens" => 7}}},
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
          "delta" => %{"type" => "input_json_delta", "partial_json" => "\"elixir\"}"}
        },
        %{"type" => "content_block_stop", "index" => 0},
        %{"type" => "message_delta", "delta" => %{}, "usage" => %{"output_tokens" => 4}}
      ]

      assert {:ok,
              %{
                message: %{
                  content: nil,
                  tool_calls: [%{id: "toolu_1", name: "web_search", args: %{"q" => "elixir"}}]
                }
              }} = Anthropic.reduce_chunks(chunks)
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
