defmodule ElGraph.LLM.Structured do
  @moduledoc """
  스키마 검증 + 오류 피드백 재시도로 LLM에서 **구조화 출력**을 얻는다 (신뢰성 패턴).

  Instructor / Pydantic AI의 핵심 루프를 ElGraph LLM 추상화 위에 올린 것:

    1. 대화를 LLM에 보내 응답(JSON)을 받는다.
    2. JSON을 디코드해 NimbleOptions 스키마로 검증한다(코드펜스로 감싸여 오면 벗긴다).
    3. 실패하면 **검증 오류를 메시지로 되먹여** 재시도한다(`:max_retries`, 기본 2).
    4. 통과하면 `{:ok, %{data: 검증된_맵, usage: 누적_usage}}`.

      schema = [name: [type: :string, required: true], age: [type: :pos_integer, required: true]]
      {:ok, %{data: %{name: "Ada", age: 36}}} =
        ElGraph.LLM.Structured.generate({MyLLM, cfg}, [ElGraph.LLM.user("a person")], schema)

  스키마는 `ElGraph.Guardrail.validate_schema/1`와 동일한 NimbleOptions keyword 형식이다.
  검증을 끝까지 통과 못 하면 `{:error, {:invalid_output, NimbleOptions.ValidationError | reason}}`,
  LLM 호출 자체가 실패하면 그 `{:error, term}`을 그대로 전파한다.
  """

  alias ElGraph.LLM

  @default_max_retries 2

  @spec generate({module(), term()}, [LLM.message()], keyword(), keyword()) ::
          {:ok, %{data: map(), usage: LLM.usage()}} | {:error, term()}
  def generate({mod, _config} = llm, messages, schema, opts \\ []) when is_atom(mod) do
    compiled = NimbleOptions.new!(schema)
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    chat_opts = Keyword.drop(opts, [:max_retries])
    zero = %{input_tokens: 0, output_tokens: 0}
    attempt(llm, messages, {compiled, schema}, chat_opts, max_retries, zero)
  end

  defp attempt({mod, config} = llm, messages, {compiled, schema} = sch, opts, retries_left, usage) do
    case mod.chat(config, messages, opts) do
      {:ok, %{message: %{content: content}, usage: call_usage}} ->
        usage = LLM.add_usage(usage, call_usage)

        case parse_and_validate(content, compiled, schema) do
          {:ok, data} ->
            {:ok, %{data: data, usage: usage}}

          {:error, reason} when retries_left > 0 ->
            messages =
              messages ++
                [LLM.assistant(content || ""), LLM.user(correction(reason))]

            attempt(llm, messages, sch, opts, retries_left - 1, usage)

          {:error, reason} ->
            {:error, {:invalid_output, reason}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_and_validate(content, compiled, schema) do
    with {:ok, decoded} <- decode_json(content),
         keyword = take_schema_keys(decoded, schema),
         {:ok, validated} <- validate(keyword, compiled) do
      {:ok, Map.new(validated)}
    end
  end

  # content 전체가 JSON이면 그대로, 아니면 ```json 펜스/주변 산문에서 객체를 추출한다.
  defp decode_json(content) when is_binary(content) do
    case object_decode(content) do
      {:ok, _map} = ok ->
        ok

      :error ->
        case Regex.run(~r/\{.*\}/s, content) do
          [json] -> with :error <- object_decode(json), do: {:error, :invalid_json}
          _ -> {:error, :invalid_json}
        end
    end
  end

  defp decode_json(_content), do: {:error, :invalid_json}

  defp object_decode(string) do
    case Jason.decode(string) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  # JSON은 문자열 키 → 스키마에 있는 키만 골라 atom 키로 변환(미정의 키 제거, atom 폭주 방지).
  defp take_schema_keys(decoded, schema) do
    for {key, _spec} <- schema, Map.has_key?(decoded, Atom.to_string(key)) do
      {key, Map.fetch!(decoded, Atom.to_string(key))}
    end
  end

  defp validate(keyword, compiled) do
    case NimbleOptions.validate(keyword, compiled) do
      {:ok, validated} -> {:ok, validated}
      {:error, %NimbleOptions.ValidationError{} = error} -> {:error, error}
    end
  end

  defp correction(%NimbleOptions.ValidationError{} = error),
    do: correction(Exception.message(error))

  defp correction(:invalid_json),
    do:
      "Your previous response was not valid JSON. Return ONLY a valid JSON object matching the schema, with no prose or code fences."

  defp correction(reason) when is_binary(reason),
    do:
      "Your previous response failed validation: #{reason}. Return ONLY a corrected, valid JSON object matching the schema, with no prose."
end
