defmodule ElGraph.DemoIntegrationTest do
  use ExUnit.Case, async: true

  alias ElGraph.Demo

  @moduletag :integration
  @moduletag timeout: 90_000

  test "the docs agent answers a real question with the real OpenAI model" do
    start_supervised!({Demo, reply_to: self()})

    :ok = Demo.ask("ElGraph의 체크포인트 보존 정책 옵션은 어떤 형태야? 문서를 검색해서 한 문장으로 답해줘.")

    assert_receive {:demo_answer, %{answer: answer, usage: usage}}, 60_000
    assert is_binary(answer) and answer != ""
    assert usage.input_tokens > 0
  end
end
