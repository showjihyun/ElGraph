defmodule ElGraph.LLM.GeminiStreamTest do
  use ExUnit.Case, async: true

  alias ElGraph.LLM.Gemini

  # Realistic Gemini streaming chunks (already JSON-decoded maps).
  defp text_chunk(text),
    do: %{"candidates" => [%{"content" => %{"parts" => [%{"text" => text}]}}]}

  describe "decode_deltas/1 — per-chunk delta events" do
    test "yields a token event for a text part" do
      assert [{:token, "Hello"}] = Gemini.decode_deltas(text_chunk("Hello"))
    end

    test "yields nothing for a functionCall chunk" do
      assert [] =
               Gemini.decode_deltas(%{
                 "candidates" => [
                   %{
                     "content" => %{
                       "parts" => [%{"functionCall" => %{"name" => "x", "args" => %{}}}]
                     }
                   }
                 ]
               })
    end

    test "yields nothing for a usage-only chunk" do
      assert [] =
               Gemini.decode_deltas(%{
                 "usageMetadata" => %{"promptTokenCount" => 1, "candidatesTokenCount" => 2}
               })
    end
  end

  describe "reduce_chunks/1 — assemble final response" do
    test "concatenates text deltas into the assistant message" do
      chunks = [text_chunk("Hel"), text_chunk("lo"), text_chunk(" world")]

      assert {:ok, %{message: %{role: :assistant, content: "Hello world", tool_calls: []}}} =
               Gemini.reduce_chunks(chunks)
    end

    test "captures usage from the last non-nil usageMetadata" do
      chunks = [
        text_chunk("hi"),
        %{
          "candidates" => [%{"content" => %{"parts" => [%{"text" => "!"}]}}],
          "usageMetadata" => %{"promptTokenCount" => 10, "candidatesTokenCount" => 3}
        }
      ]

      assert {:ok, %{usage: %{input_tokens: 10, output_tokens: 3}}} =
               Gemini.reduce_chunks(chunks)
    end

    test "nil content with accumulated tool_calls when only a functionCall streams" do
      chunks = [
        %{
          "candidates" => [
            %{
              "content" => %{
                "parts" => [
                  %{"functionCall" => %{"name" => "web_search", "args" => %{"q" => "elixir"}}}
                ]
              }
            }
          ]
        }
      ]

      assert {:ok,
              %{
                message: %{
                  content: nil,
                  tool_calls: [%{id: "web_search", name: "web_search", args: %{"q" => "elixir"}}]
                }
              }} = Gemini.reduce_chunks(chunks)
    end
  end
end
