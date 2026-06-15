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

## 실 Langfuse 송신 검증

`langfuse_export_test`(아래)는 라이브 Langfuse 없이도 exporter가 OTLP/HTTP로 보내는
**HTTP 요청의 형태**(엔드포인트·인증 헤더·protobuf 본문)를 로컬 Plug 스텁으로 포착해 검증한다.
실제 Langfuse 대시보드에 trace가 뜨는지까지 확인하려면 다음 런북을 따른다.

1. `config/secrets.exs`(저장소 루트 기준)에 Langfuse 키를 채운다:

   ```elixir
   [
     langfuse_public_key: "pk-lf-...",
     langfuse_secret_key: "sk-lf-...",
     # 선택: 자체 호스팅/리전 변경 시 (기본 EU 클라우드)
     langfuse_endpoint: "https://cloud.langfuse.com/api/public/otel"
   ]
   ```

   키는 cloud.langfuse.com 프로젝트 설정 → API Keys 에서 발급한다.
   실 OpenAI 호출도 하므로 `OPENAI_API_KEY`(또는 `ElGraph.Demo.fetch_api_key!/0`가 읽는 경로)도 필요하다.

2. 실전송 스크립트를 실행한다(실 OpenAI + 실 Langfuse):

   ```sh
   cd apps/el_graph_otel
   mix run scripts/otel_langfuse.exs
   ```

3. Langfuse UI → **Traces** 에서 다음을 확인한다:

   * `invoke_workflow` — 그래프 1회 실행에 해당하는 루트 **SPAN**
   * `chat <model>` — LLM 호출에 해당하는 **GENERATION**(모델명·input/output 토큰 수 포함)
   * 각 노드(`execute_tool ...`) — `invoke_workflow` 아래로 중첩된 **TOOL** span

> 자동화 테스트 `test/el_graph/otel/langfuse_export_test.exs`(`--include integration`)는
> 라이브 Langfuse 없이 OTLP 요청 형태(엔드포인트 `/v1/traces`, `authorization: Basic ...` +
> `x-langfuse-ingestion-version: 4` 헤더, protobuf 본문)를 검증한다. CI에서 키 없이 상시 실행된다.
