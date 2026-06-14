defmodule ElGraph.OTel.Mapping do
  @moduledoc """
  `:telemetry` 이벤트 → OpenTelemetry GenAI 시맨틱 규약 매핑 (SPEC §3.7, R5).

  순수 변환 계층이다 — OTel SDK 브리지(`el_graph_otel` 패키지)는
  `OpentelemetryTelemetry` 류 글루에서 이 모듈로 span 이름/속성을 얻는다.

  매핑 방침: L1 invoke → `invoke_workflow`, 노드 실행 → `execute_tool`,
  `thread_id` → `gen_ai.conversation.id`.
  """

  @typedoc "OTel span 이름과 속성 맵"
  @type span :: {String.t(), %{String.t() => term()}}

  @doc "telemetry 이벤트 접두사와 메타데이터를 OTel span 이름/속성으로 변환한다."
  @spec span([atom()], map()) :: span()
  def span([:el_graph, :invoke], metadata) do
    attrs =
      %{
        "gen_ai.operation.name" => "invoke_workflow",
        "gen_ai.system" => "el_graph",
        "gen_ai.conversation.id" => metadata.thread_id
      }
      |> put_error(metadata)

    {"invoke_workflow", attrs}
  end

  def span([:el_graph, :node], metadata) do
    tool_name = to_string(metadata.node)

    attrs =
      %{
        "gen_ai.operation.name" => "execute_tool",
        "gen_ai.tool.name" => tool_name,
        "gen_ai.conversation.id" => metadata.thread_id,
        "el_graph.step" => metadata.step
      }
      |> put_error(metadata)

    {"execute_tool #{tool_name}", attrs}
  end

  # LLM 호출 → GenAI chat generation. Langfuse 등이 'generation'으로 인식하는 핵심 span.
  def span([:el_graph, :llm, :chat], metadata) do
    base = %{
      "gen_ai.operation.name" => "chat",
      "gen_ai.system" => to_string(metadata.provider),
      "gen_ai.request.model" => metadata.model
    }

    attrs =
      base
      |> put_usage(metadata)
      |> put_error(metadata)

    {"chat #{metadata.model}", attrs}
  end

  defp put_usage(attrs, %{input_tokens: input, output_tokens: output}) do
    attrs
    |> Map.put("gen_ai.usage.input_tokens", input)
    |> Map.put("gen_ai.usage.output_tokens", output)
  end

  defp put_usage(attrs, _no_usage), do: attrs

  defp put_error(attrs, %{error: error}), do: Map.put(attrs, "error.type", inspect(error))
  defp put_error(attrs, _no_error), do: attrs
end
