defmodule ElGraph.LLM.Telemetry do
  @moduledoc """
  LLM 호출 계측 헬퍼 (관측/Langfuse 연동의 토대).

  `[:el_graph, :llm, :chat]` span을 낸다 — start/stop/exception 자동(`:telemetry.span`).
  stop 메타에 provider·model·토큰 사용량(성공) 또는 error(실패)를 싣는다. 이 메타가
  OTel GenAI semconv(`gen_ai.usage.*`)로 매핑되어 어느 관측 백엔드로든 흐른다.
  """

  @doc """
  LLM 호출(`fun`)을 telemetry span으로 감싼다.

  `fun`은 `{:ok, %{usage: ...}}` 또는 `{:error, reason}`을 반환해야 한다.
  """
  @spec instrument(atom(), String.t(), (-> term())) :: term()
  def instrument(provider, model, fun) do
    :telemetry.span([:el_graph, :llm, :chat], %{provider: provider, model: model}, fn ->
      result = fun.()
      {result, stop_metadata(provider, model, result)}
    end)
  end

  defp stop_metadata(
         provider,
         model,
         {:ok, %{usage: %{input_tokens: input, output_tokens: output}}}
       ) do
    %{provider: provider, model: model, input_tokens: input, output_tokens: output}
  end

  defp stop_metadata(provider, model, {:ok, _no_usage}) do
    %{provider: provider, model: model}
  end

  defp stop_metadata(provider, model, {:error, reason}) do
    %{provider: provider, model: model, error: reason}
  end
end
