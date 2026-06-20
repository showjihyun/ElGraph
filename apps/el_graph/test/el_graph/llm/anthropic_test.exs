defmodule ElGraph.LLM.AnthropicTest do
  use ExUnit.Case, async: true

  alias ElGraph.LLM
  alias ElGraph.LLM.Anthropic

  describe "request_spec/4" do
    test "converts a full conversation with tools" do
      messages = [
        %{role: :system, content: "넌 검색 봇"},
        LLM.user("검색해줘"),
        LLM.assistant("찾아볼게", [LLM.tool_call("c1", "web_search", %{"query" => "q"})]),
        LLM.tool_result("c1", "web_search", %{results: [1]})
      ]

      tools = [%{name: "web_search", description: "검색", input_schema: %{"type" => "object"}}]
      request = Anthropic.request_spec([api_key: "test-key"], messages, [tools: tools], :chat)

      assert request.url =~ "api.anthropic.com"
      assert {"x-api-key", "test-key"} in request.headers

      assert %{
               model: "claude-sonnet-4-6",
               max_tokens: 4096,
               system: "넌 검색 봇",
               messages: [
                 %{role: "user", content: "검색해줘"},
                 %{
                   role: "assistant",
                   content: [
                     %{type: "text", text: "찾아볼게"},
                     %{type: "tool_use", id: "c1", name: "web_search", input: %{"query" => "q"}}
                   ]
                 },
                 %{
                   role: "user",
                   content: [%{type: "tool_result", tool_use_id: "c1", content: tool_content}]
                 }
               ],
               tools: [%{name: "web_search", description: "검색", input_schema: _}]
             } = request.body

      assert tool_content =~ "results"
    end

    test "honors config model/max_tokens and the :system option" do
      request =
        Anthropic.request_spec(
          [api_key: "k", model: "claude-opus-4-8", max_tokens: 100],
          [LLM.user("x")],
          [system: "시스템"],
          :chat
        )

      assert %{model: "claude-opus-4-8", max_tokens: 100, system: "시스템"} = request.body
    end
  end

  describe "parse_response/1" do
    test "parses a text response with usage" do
      body = %{
        "content" => [%{"type" => "text", "text" => "안녕"}],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      assert {:ok,
              %{
                message: %{role: :assistant, content: "안녕", tool_calls: []},
                usage: %{input_tokens: 10, output_tokens: 5}
              }} = Anthropic.parse_response(body)
    end

    test "parses tool_use blocks into tool_calls" do
      body = %{
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "c9",
            "name" => "web_search",
            "input" => %{"query" => "q"}
          }
        ],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 2}
      }

      assert {:ok,
              %{
                message: %{
                  content: nil,
                  tool_calls: [%{id: "c9", name: "web_search", args: %{"query" => "q"}}]
                }
              }} = Anthropic.parse_response(body)
    end
  end

  describe "chat/3" do
    test "round-trips through HTTP" do
      Req.Test.stub(AnthropicStub, fn conn ->
        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "pong"}],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        })
      end)

      config = [api_key: "k", req_options: [plug: {Req.Test, AnthropicStub}]]

      assert {:ok, %{message: %{content: "pong"}}} =
               Anthropic.chat(config, [LLM.user("ping")], [])
    end

    test "non-200 responses are api errors" do
      Req.Test.stub(AnthropicErrStub, fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => %{"type" => "rate_limit_error"}})
      end)

      config = [api_key: "k", req_options: [plug: {Req.Test, AnthropicErrStub}]]

      assert {:error, {:api_error, 429, %{"error" => _}}} =
               Anthropic.chat(config, [LLM.user("x")], [])
    end
  end
end
