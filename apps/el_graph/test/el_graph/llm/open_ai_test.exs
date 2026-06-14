defmodule ElGraph.LLM.OpenAITest do
  use ExUnit.Case, async: true

  alias ElGraph.LLM
  alias ElGraph.LLM.OpenAI

  describe "build_request/3" do
    test "converts a full conversation with tools" do
      messages = [
        LLM.user("검색해줘"),
        LLM.assistant(nil, [LLM.tool_call("c1", "web_search", %{"query" => "q"})]),
        LLM.tool_result("c1", "web_search", %{results: [1]})
      ]

      tools = [%{name: "web_search", description: "검색", input_schema: %{"type" => "object"}}]

      request = OpenAI.build_request([api_key: "test-key"], messages, tools: tools, system: "봇")

      assert request.url =~ "api.openai.com"
      assert {"authorization", "Bearer test-key"} in request.headers

      assert %{
               model: "gpt-4o",
               messages: [
                 %{role: "system", content: "봇"},
                 %{role: "user", content: "검색해줘"},
                 %{
                   role: "assistant",
                   tool_calls: [
                     %{
                       id: "c1",
                       type: "function",
                       function: %{name: "web_search", arguments: args_json}
                     }
                   ]
                 },
                 %{role: "tool", tool_call_id: "c1", content: tool_content}
               ],
               tools: [%{type: "function", function: %{name: "web_search", parameters: _}}]
             } = request.body

      assert args_json =~ "query"
      assert tool_content =~ "results"
    end
  end

  describe "parse_response/1" do
    test "parses a text response with usage" do
      body = %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "안녕"}}],
        "usage" => %{"prompt_tokens" => 7, "completion_tokens" => 3}
      }

      assert {:ok,
              %{
                message: %{role: :assistant, content: "안녕", tool_calls: []},
                usage: %{input_tokens: 7, output_tokens: 3}
              }} = OpenAI.parse_response(body)
    end

    test "decodes tool_call JSON arguments" do
      body = %{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "c9",
                  "type" => "function",
                  "function" => %{"name" => "web_search", "arguments" => ~s({"query":"q"})}
                }
              ]
            }
          }
        ],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
      }

      assert {:ok,
              %{
                message: %{
                  content: nil,
                  tool_calls: [%{id: "c9", name: "web_search", args: %{"query" => "q"}}]
                }
              }} = OpenAI.parse_response(body)
    end
  end

  describe "chat/3" do
    test "round-trips through HTTP" do
      Req.Test.stub(OpenAIStub, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "pong"}}],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
        })
      end)

      config = [api_key: "k", req_options: [plug: {Req.Test, OpenAIStub}]]

      assert {:ok, %{message: %{content: "pong"}}} = OpenAI.chat(config, [LLM.user("ping")], [])
    end

    test "non-200 responses are api errors" do
      Req.Test.stub(OpenAIErrStub, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
      end)

      config = [api_key: "k", req_options: [plug: {Req.Test, OpenAIErrStub}]]

      assert {:error, {:api_error, 500, _body}} = OpenAI.chat(config, [LLM.user("x")], [])
    end
  end
end
