defmodule ElGraph.LLM.ReqLLMTest do
  use ExUnit.Case, async: true

  alias ElGraph.LLM
  alias ElGraph.LLM.ReqLLM, as: Adapter

  describe "encode_context/2" do
    test "maps user/system/assistant/tool messages to a ReqLLM context in order" do
      messages = [
        LLM.user("검색해줘"),
        LLM.assistant(nil, [LLM.tool_call("c1", "web_search", %{"query" => "q"})]),
        LLM.tool_result("c1", "web_search", %{results: [1]})
      ]

      ctx = Adapter.encode_context(messages, system: "너는 봇이다")

      assert %ReqLLM.Context{} = ctx
      assert Enum.map(ctx.messages, & &1.role) == [:system, :user, :assistant, :tool]
    end

    test "no system option omits the system message" do
      ctx = Adapter.encode_context([LLM.user("hi")], [])
      assert Enum.map(ctx.messages, & &1.role) == [:user]
    end
  end

  describe "encode_tools/1" do
    test "maps ElGraph tool specs to ReqLLM tools, passing the JSON schema through" do
      specs = [
        %{name: "web_search", description: "검색", input_schema: %{"type" => "object"}}
      ]

      assert [%ReqLLM.Tool{} = tool] = Adapter.encode_tools(specs)
      assert tool.name == "web_search"
      assert tool.description == "검색"
      assert tool.parameter_schema == %{"type" => "object"}
      assert is_function(tool.callback, 1)
    end

    test "nil/empty tool lists become nil (omitted from the request)" do
      assert Adapter.encode_tools(nil) == nil
      assert Adapter.encode_tools([]) == nil
    end
  end

  describe "decode_response/1" do
    test "a text response becomes an assistant message with usage" do
      response = %ReqLLM.Response{
        id: "r1",
        model: "openai:gpt-4o",
        context: ReqLLM.Context.new([]),
        message: ReqLLM.Context.assistant("pong"),
        usage: %{input_tokens: 7, output_tokens: 3}
      }

      assert {:ok,
              %{
                message: %{role: :assistant, content: "pong", tool_calls: []},
                usage: %{input_tokens: 7, output_tokens: 3}
              }} = Adapter.decode_response(response)
    end

    test "a tool-call response yields ElGraph tool_calls with a map of args and nil content" do
      message =
        ReqLLM.Context.assistant("", tool_calls: [{"web_search", %{"query" => "q"}, id: "c9"}])

      response = %ReqLLM.Response{
        id: "r2",
        model: "openai:gpt-4o",
        context: ReqLLM.Context.new([]),
        message: message,
        usage: %{input_tokens: 1, output_tokens: 1}
      }

      assert {:ok, %{message: %{content: nil, tool_calls: [tool_call]}}} =
               Adapter.decode_response(response)

      assert %{id: "c9", name: "web_search", args: %{"query" => "q"}} = tool_call
    end
  end
end
