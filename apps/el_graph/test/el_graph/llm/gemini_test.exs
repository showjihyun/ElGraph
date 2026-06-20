defmodule ElGraph.LLM.GeminiTest do
  use ExUnit.Case, async: true

  alias ElGraph.LLM
  alias ElGraph.LLM.Gemini

  describe "request_spec/4" do
    test "converts a full conversation with tools" do
      messages = [
        LLM.user("검색해줘"),
        LLM.assistant(nil, [LLM.tool_call("web_search", "web_search", %{"query" => "q"})]),
        LLM.tool_result("web_search", "web_search", %{results: [1]})
      ]

      tools = [%{name: "web_search", description: "검색", input_schema: %{"type" => "object"}}]

      request =
        Gemini.request_spec([api_key: "test-key"], messages, [tools: tools, system: "봇"], :chat)

      assert request.url =~ "generativelanguage.googleapis.com"
      assert request.url =~ ":generateContent"
      assert {"x-goog-api-key", "test-key"} in request.headers

      assert %{
               systemInstruction: %{parts: [%{text: "봇"}]},
               contents: [
                 %{role: "user", parts: [%{text: "검색해줘"}]},
                 %{
                   role: "model",
                   parts: [%{functionCall: %{name: "web_search", args: %{"query" => "q"}}}]
                 },
                 %{
                   role: "user",
                   parts: [%{functionResponse: %{name: "web_search", response: %{content: _}}}]
                 }
               ],
               tools: [%{functionDeclarations: [%{name: "web_search", parameters: _}]}]
             } = request.body
    end
  end

  describe "parse_response/1" do
    test "parses a text response with usage" do
      body = %{
        "candidates" => [%{"content" => %{"parts" => [%{"text" => "안녕"}]}}],
        "usageMetadata" => %{"promptTokenCount" => 9, "candidatesTokenCount" => 4}
      }

      assert {:ok,
              %{
                message: %{role: :assistant, content: "안녕", tool_calls: []},
                usage: %{input_tokens: 9, output_tokens: 4}
              }} = Gemini.parse_response(body)
    end

    test "parses functionCall parts; the tool name doubles as the id" do
      body = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{"functionCall" => %{"name" => "web_search", "args" => %{"query" => "q"}}}
              ]
            }
          }
        ],
        "usageMetadata" => %{"promptTokenCount" => 1, "candidatesTokenCount" => 1}
      }

      assert {:ok,
              %{
                message: %{
                  content: nil,
                  tool_calls: [%{id: "web_search", name: "web_search", args: %{"query" => "q"}}]
                }
              }} = Gemini.parse_response(body)
    end
  end

  describe "chat/3" do
    test "round-trips through HTTP" do
      Req.Test.stub(GeminiStub, fn conn ->
        Req.Test.json(conn, %{
          "candidates" => [%{"content" => %{"parts" => [%{"text" => "pong"}]}}],
          "usageMetadata" => %{"promptTokenCount" => 1, "candidatesTokenCount" => 1}
        })
      end)

      config = [api_key: "k", req_options: [plug: {Req.Test, GeminiStub}]]

      assert {:ok, %{message: %{content: "pong"}}} = Gemini.chat(config, [LLM.user("ping")], [])
    end

    test "non-200 responses are api errors" do
      Req.Test.stub(GeminiErrStub, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"error" => %{"status" => "PERMISSION_DENIED"}})
      end)

      config = [api_key: "k", req_options: [plug: {Req.Test, GeminiErrStub}]]

      assert {:error, {:api_error, 403, _body}} = Gemini.chat(config, [LLM.user("x")], [])
    end
  end
end
