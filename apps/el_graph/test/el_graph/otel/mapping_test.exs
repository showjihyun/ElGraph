defmodule ElGraph.OTel.MappingTest do
  use ExUnit.Case, async: true

  alias ElGraph.OTel.Mapping

  describe "OTel GenAI semconv 매핑 (SPEC §3.7)" do
    test "invoke spans map to invoke_workflow with the conversation id" do
      assert {"invoke_workflow",
              %{
                "gen_ai.operation.name" => "invoke_workflow",
                "gen_ai.system" => "el_graph",
                "gen_ai.conversation.id" => "t1"
              }} = Mapping.span([:el_graph, :invoke], %{thread_id: "t1"})
    end

    test "node spans map to execute_tool with the tool name and step" do
      assert {"execute_tool greet",
              %{
                "gen_ai.operation.name" => "execute_tool",
                "gen_ai.tool.name" => "greet",
                "gen_ai.conversation.id" => "t1",
                "el_graph.step" => 2
              }} = Mapping.span([:el_graph, :node], %{node: :greet, step: 2, thread_id: "t1"})
    end

    test "llm.chat spans map to a GenAI chat generation with usage (Langfuse generation)" do
      assert {"chat gpt-4o",
              %{
                "gen_ai.operation.name" => "chat",
                "gen_ai.system" => "openai",
                "gen_ai.request.model" => "gpt-4o",
                "gen_ai.usage.input_tokens" => 11,
                "gen_ai.usage.output_tokens" => 4
              }} =
               Mapping.span([:el_graph, :llm, :chat], %{
                 provider: :openai,
                 model: "gpt-4o",
                 input_tokens: 11,
                 output_tokens: 4
               })
    end

    test "llm.chat error spans carry error.type" do
      assert {"chat gpt-4o", %{"error.type" => _}} =
               Mapping.span([:el_graph, :llm, :chat], %{
                 provider: :openai,
                 model: "gpt-4o",
                 error: {:api_error, 429, %{}}
               })
    end
  end

  describe "실행기 telemetry 메타데이터와의 정합" do
    test "node telemetry events carry the thread_id needed for conversation correlation" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:el_graph, :node, :stop]])

      graph =
        ElGraph.new()
        |> ElGraph.state(:result)
        |> ElGraph.add_node(:greet, &ElGraph.TestNodes.greet/2)
        |> ElGraph.compile(entry: :greet)

      {:ok, _state} = ElGraph.invoke(graph, %{}, thread_id: "corr-1")

      assert_receive {[:el_graph, :node, :stop], ^ref, %{duration: _},
                      %{node: :greet, thread_id: "corr-1"}}
    end
  end
end
