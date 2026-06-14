defmodule ElGraph.LLM.OpenAIStreamTest do
  use ExUnit.Case, async: true

  alias ElGraph.LLM.OpenAI

  # Realistic OpenAI streaming chunks (already JSON-decoded maps).
  defp text_chunk(delta), do: %{"choices" => [%{"delta" => %{"content" => delta}}]}

  describe "decode_deltas/1 — per-chunk delta events" do
    test "yields a token event for a content delta" do
      assert [{:token, "Hello"}] = OpenAI.decode_deltas(text_chunk("Hello"))
    end

    test "yields nothing for a chunk with no content delta" do
      assert [] = OpenAI.decode_deltas(%{"choices" => [%{"delta" => %{}}]})
    end

    test "yields nothing for a usage-only final chunk" do
      assert [] =
               OpenAI.decode_deltas(%{
                 "choices" => [],
                 "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 2}
               })
    end
  end

  describe "reduce_chunks/1 — assemble final response" do
    test "concatenates text deltas into the assistant message" do
      chunks = [text_chunk("Hel"), text_chunk("lo"), text_chunk(" world")]

      assert {:ok, %{message: %{role: :assistant, content: "Hello world", tool_calls: []}}} =
               OpenAI.reduce_chunks(chunks)
    end

    test "captures usage from the final chunk" do
      chunks = [
        text_chunk("hi"),
        %{"choices" => [], "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 3}}
      ]

      assert {:ok, %{usage: %{input_tokens: 10, output_tokens: 3}}} =
               OpenAI.reduce_chunks(chunks)
    end

    test "nil content when only tool calls are streamed" do
      chunks = [
        %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "id" => "call_1",
                    "function" => %{"name" => "web_search", "arguments" => ""}
                  }
                ]
              }
            }
          ]
        },
        %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "{\"q\":"}}]
              }
            }
          ]
        },
        %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "\"elixir\"}"}}]
              }
            }
          ]
        }
      ]

      assert {:ok,
              %{
                message: %{
                  content: nil,
                  tool_calls: [%{id: "call_1", name: "web_search", args: %{"q" => "elixir"}}]
                }
              }} = OpenAI.reduce_chunks(chunks)
    end
  end
end
