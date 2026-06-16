defmodule ElGraph.OTel.Bridge do
  @moduledoc """
  ElGraph telemetry span ↔ OpenTelemetry span 브리지 (Langfuse 등 OTLP 백엔드 연동).

  `attach/0`이 ElGraph의 telemetry span(`[:el_graph, :invoke|:node|:llm,:chat]`)을
  OTel span으로 변환한다 — 이름·속성은 `ElGraph.OTel.Mapping`의 GenAI semconv를 쓴다.
  `opentelemetry_telemetry`가 span 컨텍스트(부모-자식)를 관리하므로 같은 프로세스 내
  중첩(invoke → node → llm.chat)은 하나의 trace로 묶인다.

  병렬 노드는 별도 Task(프로세스)지만 `Executor.exec_all`이 부모 OTel 컨텍스트를 캡처해
  각 Task에서 attach하므로, 병렬 브랜치 span도 같은 invoke trace 아래로 중첩된다
  (검증: `langfuse_pipeline_test.exs`).

  ## Langfuse 연동

  OTLP exporter를 Langfuse로 설정하고 brige를 attach한다:

      # config/runtime.exs
      config :opentelemetry, :processors,
        otel_batch_processor: %{exporter: {:opentelemetry_exporter, %{}}}

      config :opentelemetry_exporter,
        ElGraph.OTel.Bridge.langfuse_otlp_config("pk-lf-...", "sk-lf-...")

      # 앱 시작 후
      ElGraph.OTel.Bridge.attach()
  """

  alias ElGraph.OTel.Mapping

  @tracer :el_graph
  @handler_id "el-graph-otel-bridge"
  @prefixes [[:el_graph, :invoke], [:el_graph, :node], [:el_graph, :llm, :chat]]

  @doc "ElGraph telemetry span을 OTel span으로 브리지하는 핸들러를 등록한다."
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    events =
      Enum.flat_map(@prefixes, fn p -> [p ++ [:start], p ++ [:stop], p ++ [:exception]] end)

    :telemetry.attach_many(@handler_id, events, &__MODULE__.handle_event/4, %{})
  end

  @doc "브리지 핸들러를 해제한다."
  @spec detach() :: :ok | {:error, :not_found}
  def detach, do: :telemetry.detach(@handler_id)

  @doc false
  def handle_event(event, _measurements, metadata, _config) do
    {prefix, phase} = Enum.split(event, length(event) - 1)

    case phase do
      [:start] ->
        {name, _attrs} = Mapping.span(prefix, metadata)
        OpentelemetryTelemetry.start_telemetry_span(@tracer, name, metadata, %{})

      [:stop] ->
        ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer, metadata)
        {_name, attrs} = Mapping.span(prefix, metadata)
        OpenTelemetry.Span.set_attributes(ctx, clean(attrs))
        OpentelemetryTelemetry.end_telemetry_span(@tracer, metadata)

      [:exception] ->
        ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer, metadata)
        OpenTelemetry.Span.set_status(ctx, OpenTelemetry.status(:error, "exception"))
        OpentelemetryTelemetry.end_telemetry_span(@tracer, metadata)
    end

    :ok
  end

  @doc """
  Langfuse OTLP/HTTP exporter 설정을 만든다.

  `:endpoint`(기본 EU 클라우드), `:region`은 무시되고 endpoint를 직접 준다.
  반환값은 `:opentelemetry_exporter` application env에 그대로 넣는다.
  """
  @spec langfuse_otlp_config(String.t(), String.t(), keyword()) :: keyword()
  def langfuse_otlp_config(public_key, secret_key, opts \\ []) do
    endpoint = Keyword.get(opts, :endpoint, "https://cloud.langfuse.com/api/public/otel")
    auth = Base.encode64("#{public_key}:#{secret_key}")

    [
      otlp_protocol: :http_protobuf,
      otlp_endpoint: endpoint,
      otlp_headers: [
        {"authorization", "Basic #{auth}"},
        {"x-langfuse-ingestion-version", "4"}
      ]
    ]
  end

  defp clean(attrs), do: attrs |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
end
