defmodule ElGraph.LLM.TelemetryTest do
  use ExUnit.Case, async: true

  alias ElGraph.LLM
  alias ElGraph.LLM.{Anthropic, Gemini, OpenAI}

  defp attach do
    :telemetry_test.attach_event_handlers(self(), [
      [:el_graph, :llm, :chat, :start],
      [:el_graph, :llm, :chat, :stop],
      [:el_graph, :llm, :chat, :exception]
    ])
  end

  describe "OpenAI chat instrumentation" do
    test "emits a llm.chat span with provider, model and token usage" do
      Req.Test.stub(OAITel, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}],
          "usage" => %{"prompt_tokens" => 11, "completion_tokens" => 4}
        })
      end)

      ref = attach()
      config = [api_key: "k", model: "gpt-4o", req_options: [plug: {Req.Test, OAITel}]]

      assert {:ok, _} = OpenAI.chat(config, [LLM.user("hi")], [])

      assert_receive {[:el_graph, :llm, :chat, :start], ^ref, %{},
                      %{provider: :openai, model: "gpt-4o"}}

      assert_receive {[:el_graph, :llm, :chat, :stop], ^ref, %{duration: _},
                      %{provider: :openai, model: "gpt-4o", input_tokens: 11, output_tokens: 4}}
    end

    test "an api error still closes the span with error metadata" do
      Req.Test.stub(OAIErr, fn conn ->
        conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"error" => "rate"})
      end)

      ref = attach()
      config = [api_key: "k", req_options: [plug: {Req.Test, OAIErr}]]

      assert {:error, {:api_error, 429, _}} = OpenAI.chat(config, [LLM.user("x")], [])

      assert_receive {[:el_graph, :llm, :chat, :stop], ^ref, %{duration: _},
                      %{provider: :openai, error: {:api_error, 429, _}}}
    end
  end

  describe "Anthropic chat instrumentation" do
    test "emits a span with provider :anthropic and usage" do
      Req.Test.stub(AntTel, fn conn ->
        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "ok"}],
          "usage" => %{"input_tokens" => 7, "output_tokens" => 2}
        })
      end)

      ref = attach()
      config = [api_key: "k", model: "claude-sonnet-4-6", req_options: [plug: {Req.Test, AntTel}]]

      assert {:ok, _} = Anthropic.chat(config, [LLM.user("hi")], [])

      assert_receive {[:el_graph, :llm, :chat, :stop], ^ref, %{duration: _},
                      %{
                        provider: :anthropic,
                        model: "claude-sonnet-4-6",
                        input_tokens: 7,
                        output_tokens: 2
                      }}
    end
  end

  describe "Gemini chat instrumentation" do
    test "emits a span with provider :gemini and usage" do
      Req.Test.stub(GemTel, fn conn ->
        Req.Test.json(conn, %{
          "candidates" => [%{"content" => %{"parts" => [%{"text" => "ok"}]}}],
          "usageMetadata" => %{"promptTokenCount" => 5, "candidatesTokenCount" => 3}
        })
      end)

      ref = attach()
      config = [api_key: "k", model: "gemini-2.5-flash", req_options: [plug: {Req.Test, GemTel}]]

      assert {:ok, _} = Gemini.chat(config, [LLM.user("hi")], [])

      assert_receive {[:el_graph, :llm, :chat, :stop], ^ref, %{duration: _},
                      %{
                        provider: :gemini,
                        model: "gemini-2.5-flash",
                        input_tokens: 5,
                        output_tokens: 3
                      }}
    end
  end
end
