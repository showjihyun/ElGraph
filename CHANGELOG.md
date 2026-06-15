# Changelog

이 프로젝트의 주요 변경 사항. 형식은 [Keep a Changelog](https://keepachangelog.com/),
버전은 [SemVer](https://semver.org/)를 따른다.

## [0.2.0] — 2026-06-15

2026 Agentic AI 트렌드 보고서(`docs/agentic-ai-2026-report.html`)를 근거로 한 기능 확장 +
품질 강화. 모든 변경은 TDD로 진행했고 전 앱 Dialyzer 0 경고.

### Added

- **AG-UI 프로토콜** — `ElGraph.AGUI` 순수 매핑(RUN/STEP/TEXT_MESSAGE/TOOL_CALL/STATE_SNAPSHOT/
  STATE_DELTA/MESSAGES_SNAPSHOT/CUSTOM), `transform/3`·`encode/1`.
- **HTTP 서버 앱 `el_graph_web`** — Plug/Bandit. A2A JSON-RPC 2.0(`message/send`·`tasks/get`·
  `message/stream` SSE), `.well-known/agent-card.json`, `TaskStore`, AG-UI `/agui/:name/run` SSE.
  API키 인증 plug + 입력 가드레일.
- **LLM SSE 스트리밍** — `stream_chat/3`(OpenAI/Anthropic/Gemini), 증분 토큰 + 증분 도구호출
  델타(3개 어댑터 동치), `LLM.stream_to_ctx/4`, `LLM.SSE` 파서.
- **오케스트레이션 템플릿** — `ElGraph.Orchestration`: supervisor(오케스트레이터-워커),
  group_chat(스피커 선택), magentic(task-ledger: task+facts+stall guard).
- **고급 메모리** — `ElGraph.Memory`: episodic/semantic/procedural 스코프 + 시점진실,
  시맨틱 recall(`Embedder` + cosine), `fact_history/3`, `forget/4`. `Nodes.Memory`(그래프 연동).
- **평가** — `ElGraph.Eval`: 데이터셋 평가 + LLM-judge + 체크포인트-리플레이 평가 + 병렬 +
  집계 메트릭 + JSONL 로딩 + baseline 회귀 비교.
- **가드레일** — `ElGraph.Guardrail`: deny/redact/max_length/authorize_tool + PII 라이브러리 +
  구조화 출력 검증 + 차단 telemetry. ReAct 프리셋(`guardrails:`) + el_graph_web에 연동.
- **샌드박스 코드 실행** — `ElGraph.Sandbox`(behaviour) + `.Command`/`.Docker` + `Actions.CodeExec`
  (ReAct 툴로 등록). 타임아웃·출력 제한, Docker network=none/read-only.
- **내구 체크포인터** — DETS·Mnesia(코어) + `el_graph_ecto`(Postgres) + `el_graph_redis`
  (Valkey/Redis). `durability: :sync|:async|:exit`, `keep:` 보존 정책.
- **관측** — OTel 병렬노드 컨텍스트 전파, Agent/Bus/checkpoint telemetry,
  GenAI semconv 매핑(invoke_workflow/execute_tool/chat/invoke_agent). Langfuse OTLP 연동.
  ElTrace LiveView(타임라인·인터럽트 승인/거절·time-travel 분기).

### Changed

- A2A·OTel은 순수 매핑 계층으로 분리, HTTP/SDK 브리지는 별도 패키지 몫.

### Fixed

- **타입 버그(Dialyzer 도입 중 발견)** — 노드/라우터/reducer 타입이 `mfa()`(=arity)로 잘못
  선언돼 있던 것을 `Graph.mfargs()`(`{module, fun, [args]}`)로 정정.
- `ElTrace.Telemetry.attach/0` 반환 계약을 `:ok`로 명시.

### Tooling

- **Dialyzer** — 움브렐라 5개 앱 전부 `mix dialyzer` 0 경고.
- **CI** — GitHub Actions(`.github/workflows/ci.yml`): format/test/dialyzer 자동 강제,
  Postgres/Valkey 서비스 통합 잡, live_llm 시크릿 게이트.
- **docker-compose.yml** — 로컬 Postgres/Valkey. `.gitattributes`로 소스 LF 고정.

## [0.1.0]

- ElGraph 코어(L1~L4): 그래프 실행기, 체크포인트(pending writes/버전), HITL 인터럽트,
  스트리밍, 취소, Action/Tool, LLM behaviour, Agent 런타임, Signal Bus, Skill, Sensor,
  Store, A2A 매핑. 상세는 `docs/SPEC.md`.
