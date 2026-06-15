# ElGraphOtel

ElGraph 텔레메트리 → OpenTelemetry SDK 브리지. 무거운 OTel SDK/exporter 의존성을
코어(`el_graph`)에서 격리하기 위한 별도 우산 앱이다 (SPEC §13: 의존성 최소화).

코어 `el_graph`는 executor의 컨텍스트 전파에 필요한 `opentelemetry_api`만 유지하고,
실제 SDK(`opentelemetry`, `opentelemetry_exporter`, `opentelemetry_telemetry`)와
브리지 핸들러는 이 앱에 둔다.

## 사용

호스트 앱에서 OTLP exporter(예: Langfuse)를 구성한 뒤 브리지를 attach 한다:

```elixir
config :opentelemetry_exporter,
  ElGraph.OTel.Bridge.langfuse_otlp_config("pk-lf-...", "sk-lf-...")

ElGraph.OTel.Bridge.attach()
```

`scripts/otel_langfuse.exs`, `scripts/otel_observe.exs`에 실전송 예제가 있다.
