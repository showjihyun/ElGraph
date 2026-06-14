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
end
