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

  describe "stream_step/3 — stateful incremental delta reducer" do
    defp collect(on), do: fn delta -> send(on, {:delta, delta}) end

    defp fold(chunks, on_delta) do
      Enum.reduce(chunks, %{tool_index_to_id: %{}}, fn chunk, acc ->
        OpenAI.stream_step(chunk, acc, on_delta)
      end)
    end

    test "emits a token delta for content chunks" do
      fold([text_chunk("Hi")], collect(self()))
      assert_received {:delta, {:token, "Hi"}}
    end

    test "emits start/delta/end deltas for an incrementally streamed tool call" do
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
                "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "{\"q"}}]
              }
            }
          ]
        },
        %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "\":\"x\"}"}}]
              }
            }
          ]
        },
        %{"choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}]}
      ]

      fold(chunks, collect(self()))

      assert_received {:delta, {:tool_call_start, "call_1", "web_search"}}
      assert_received {:delta, {:tool_call_delta, "call_1", "{\"q"}}
      assert_received {:delta, {:tool_call_delta, "call_1", "\":\"x\"}"}}
      assert_received {:delta, {:tool_call_end, "call_1"}}
    end

    test "does not re-emit tool_call_start for the same index" do
      chunks = [
        %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "id" => "call_1",
                    "function" => %{"name" => "f", "arguments" => ""}
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
                "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "a"}}]
              }
            }
          ]
        }
      ]

      fold(chunks, collect(self()))

      assert_received {:delta, {:tool_call_start, "call_1", "f"}}
      assert_received {:delta, {:tool_call_delta, "call_1", "a"}}
      refute_received {:delta, {:tool_call_start, "call_1", "f"}}
    end
  end

  describe "stream_chat/3 via Req.Test — end-to-end SSE behavior" do
    test "streams text deltas and assembles the final response" do
      sse =
        ~s(data: {"choices":[{"delta":{"content":"Hel"}}]}\n\n) <>
          ~s(data: {"choices":[{"delta":{"content":"lo"}}]}\n\n) <>
          ~s(data: {"choices":[{"delta":{"content":" world"}}]}\n\n) <>
          ~s(data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2}}\n\n) <>
          ~s(data: [DONE]\n\n)

      Req.Test.stub(OpenAIStreamTextStub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse)
      end)

      config = [api_key: "k", req_options: [plug: {Req.Test, OpenAIStreamTextStub}]]
      parent = self()

      assert {:ok,
              %{
                message: %{role: :assistant, content: "Hello world", tool_calls: []},
                usage: %{input_tokens: 3, output_tokens: 2}
              }} =
               OpenAI.stream_chat(config, [ElGraph.LLM.user("hi")],
                 on_delta: fn d -> send(parent, {:delta, d}) end
               )

      assert_received {:delta, {:token, "Hel"}}
      assert_received {:delta, {:token, "lo"}}
      assert_received {:delta, {:token, " world"}}
    end

    test "streams incremental tool-call deltas and assembles tool_calls" do
      sse =
        ~s(data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"web_search","arguments":""}}]}}]}\n\n) <>
          ~s(data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"q\\":"}}]}}]}\n\n) <>
          ~s(data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"elixir\\"}"}}]}}]}\n\n) <>
          ~s(data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n\n) <>
          ~s(data: [DONE]\n\n)

      Req.Test.stub(OpenAIStreamToolStub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse)
      end)

      config = [api_key: "k", req_options: [plug: {Req.Test, OpenAIStreamToolStub}]]
      parent = self()

      assert {:ok,
              %{
                message: %{
                  role: :assistant,
                  content: nil,
                  tool_calls: [%{id: "call_1", name: "web_search", args: %{"q" => "elixir"}}]
                }
              }} =
               OpenAI.stream_chat(config, [ElGraph.LLM.user("search")],
                 on_delta: fn d -> send(parent, {:delta, d}) end
               )

      assert_received {:delta, {:tool_call_start, "call_1", "web_search"}}
      assert_received {:delta, {:tool_call_delta, "call_1", "{\"q\":"}}
      assert_received {:delta, {:tool_call_delta, "call_1", "\"elixir\"}"}}
      assert_received {:delta, {:tool_call_end, "call_1"}}
    end

    test "maps a 500 streaming response to {:api_error, 500, body}" do
      Req.Test.stub(OpenAIStream500Stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(500, "boom")
      end)

      config = [api_key: "k", req_options: [plug: {Req.Test, OpenAIStream500Stub}]]

      assert {:error, {:api_error, 500, _body}} =
               OpenAI.stream_chat(config, [ElGraph.LLM.user("hi")], [])
    end
  end

  describe "stream_chat/3 — error handling" do
    test "maps a non-200 streaming response to {:api_error, status, body}" do
      Req.Test.stub(OpenAIStreamErrStub, fn conn ->
        conn |> Plug.Conn.put_status(429) |> Plug.Conn.send_resp(429, "rate limited")
      end)

      config = [api_key: "k", req_options: [plug: {Req.Test, OpenAIStreamErrStub}]]

      assert {:error, {:api_error, 429, _body}} =
               OpenAI.stream_chat(config, [ElGraph.LLM.user("hi")], [])
    end

    test "maps a transport failure to {:transport_error, exception}" do
      Req.Test.stub(OpenAIStreamTransportStub, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      config = [api_key: "k", req_options: [plug: {Req.Test, OpenAIStreamTransportStub}]]

      assert {:error, {:transport_error, %Req.TransportError{reason: :econnrefused}}} =
               OpenAI.stream_chat(config, [ElGraph.LLM.user("hi")], [])
    end
  end
end
