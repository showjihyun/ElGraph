defmodule ElGraph.LLM.GeminiIntegrationTest do
  use ExUnit.Case, async: true

  alias ElGraph.{LLM, Secrets}
  alias ElGraph.LLM.Gemini

  @moduletag :integration
  @moduletag timeout: 60_000

  defp config, do: [api_key: Secrets.fetch!(:gemini_api_key)]

  test "chat round-trips against the real Gemini API" do
    assert {:ok, %{message: %{role: :assistant, content: content}, usage: usage}} =
             Gemini.chat(config(), [LLM.user("What is 2+2? Reply with the number only.")], [])

    assert content =~ "4"
    assert usage.input_tokens > 0
    assert usage.output_tokens > 0
  end

  test "stream_chat streams token deltas and returns the assembled response" do
    parent = self()

    assert {:ok, %{message: %{role: :assistant, content: content}, usage: usage}} =
             Gemini.stream_chat(
               config(),
               [LLM.user("Count: one two three. Reply with exactly those three words.")],
               on_delta: fn {:token, t} -> send(parent, {:token, t}) end
             )

    assert is_binary(content) and content != ""
    assert usage.input_tokens > 0
    assert_received {:token, _}
  end
end
