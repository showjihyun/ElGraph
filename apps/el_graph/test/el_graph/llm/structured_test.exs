defmodule ElGraph.LLM.StructuredTest do
  use ExUnit.Case, async: true

  alias ElGraph.LLM
  alias ElGraph.LLM.Structured
  alias ElGraph.Test.ScriptedLLM

  @schema [name: [type: :string, required: true], age: [type: :pos_integer, required: true]]

  defp llm(script) do
    {:ok, pid} = ScriptedLLM.start_link(script)
    {ScriptedLLM, pid}
  end

  test "returns validated data on a valid first response" do
    llm = llm([LLM.assistant(~s({"name": "Ada", "age": 36}))])

    assert {:ok, %{data: %{name: "Ada", age: 36}, usage: usage}} =
             Structured.generate(llm, [LLM.user("a person")], @schema)

    assert %{input_tokens: _, output_tokens: _} = usage
  end

  test "retries with an error-feedback message when validation fails, then succeeds" do
    {:ok, pid} =
      ScriptedLLM.start_link([
        # age 누락 → 검증 실패
        LLM.assistant(~s({"name": "Ada"})),
        LLM.assistant(~s({"name": "Ada", "age": 36}))
      ])

    assert {:ok, %{data: %{name: "Ada", age: 36}}} =
             Structured.generate({ScriptedLLM, pid}, [LLM.user("a person")], @schema)

    # 두 번째 호출에 원본 + assistant(invalid) + 교정 user 메시지가 누적됐다.
    assert [%{messages: first}, %{messages: second}] = ScriptedLLM.calls(pid)
    assert length(first) == 1
    assert [%{role: :user}, %{role: :assistant}, %{role: :user, content: correction}] = second
    assert correction =~ "valid"
  end

  test "strips a ```json code fence before decoding" do
    llm = llm([LLM.assistant("```json\n{\"name\": \"Ada\", \"age\": 36}\n```")])

    assert {:ok, %{data: %{name: "Ada", age: 36}}} =
             Structured.generate(llm, [LLM.user("a person")], @schema)
  end

  test "returns {:error, {:invalid_output, _}} after retries are exhausted" do
    llm = llm([LLM.assistant(~s({"name": "Ada"})), LLM.assistant("still not json")])

    assert {:error, {:invalid_output, _}} =
             Structured.generate(llm, [LLM.user("a person")], @schema, max_retries: 1)
  end

  test "propagates a chat error" do
    llm = llm([{:error, :boom}])
    assert {:error, :boom} = Structured.generate(llm, [LLM.user("a person")], @schema)
  end

  test "accumulates usage across retries" do
    {:ok, pid} =
      ScriptedLLM.start_link([
        LLM.assistant(~s({"name": "Ada"})),
        LLM.assistant(~s({"name": "Ada", "age": 36}))
      ])

    assert {:ok, %{usage: %{input_tokens: _, output_tokens: _}}} =
             Structured.generate({ScriptedLLM, pid}, [LLM.user("a person")], @schema)
  end
end
