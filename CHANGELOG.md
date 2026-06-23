# Changelog

이 프로젝트의 주요 변경 사항. 형식은 [Keep a Changelog](https://keepachangelog.com/),
버전은 [SemVer](https://semver.org/)를 따른다.

## [Unreleased]

FE/BE 소스 리뷰(다중 SubAgent) 후속 — 발견한 HIGH 항목과 마무리 항목을 전부 TDD로 클로저.
코드 정본 기준 SPEC 동기화. 기본 스위트(el_graph 593 · el_graph_web 57 · el_trace 51 ·
el_graph_req_llm 9 · el_graph_otel 3) 통과, 변경 앱 dialyzer 0.

### Security

- **A2A Task IDOR 차단.** `tasks/get`이 호출자 스코프로 제한된다 — Task는 생성한 호출자
  소유로 저장되고 다른 키로는 조회 불가. Task id는 단조 정수에서 **128비트 난수**
  (`:crypto.strong_rand_bytes`)로 바뀌어 열거 불가.
- **상수 시간 토큰 비교.** `ElGraphWeb.Auth`가 API 키를 `Plug.Crypto.secure_compare`로
  비교한다(`==` 단축평가 타이밍 사이드채널 제거) + 성공 시 호출자별 opaque id 부여.
- **`TaskStore` 상한.** 무한 증가(메모리 고갈) 방지 — 설정 가능한 최대치(기본 10 000)의
  FIFO 축출.

### Fixed

- **el_trace 무한 증가 차단.** `Handoff.Collector` 엣지 버퍼 바운드(prepend+상한),
  `Sessions` 레지스트리 축출(단조 seq), 두 telemetry 핸들러에 catch-all(예상치 못한 메타데이터
  shape에 raise→영구 detach되던 것 차단), `Timeline.build`가 사라진 체크포인트를 건너뜀.
- **체크포인터 직렬화 검증 강화.** 5개 어댑터(ETS/DETS/Mnesia/Postgres/Redis)가 `.state`뿐
  아니라 **체크포인트 전체**(task_cache·interrupt_info 포함)의 직렬화 가능성을 검사 — pid/ref가
  영속 후 죽은 pid로 부활하던 손상 차단. `ElGraph.Memory` 쓰기도 동일 검증.
- **체크포인터 동시-prune TOCTOU 내성.** `get(:latest)`/`list`가 `list`와 lookup 사이의 동시
  prune에 MatchError로 죽지 않고 `:not_found`/건너뜀으로 처리(ETS/DETS/Mnesia).
- **`ElGraph.LLM.ReqLLM.chat/3` 토털화.** 형태가 어긋난 메시지(알 수 없는 role, 잘못된 tool_call,
  키 누락)에 크래시하지 않고 `{:error, {:invalid_message, _}}` 반환(네트워크 I/O 전 단락).
- **`ElGraph.Memory.forget/4` :episodic.** `FunctionClauseError` 대신
  `{:error, :episodic_not_supported}` 반환.
- **`ElGraph.A2A.message_to_input/1` 견고화.** `"parts"` 없는/형태 어긋난 메시지에 HTTP 500
  대신 빈 질문 반환.

### Changed / Docs

- **SPEC 코드 동기화.** `docs/SPEC.md`를 코드 정본에 맞춤 — stale "미구현/잔여" 표기 제거
  (SSE 스트리밍·el_graph_otel·핸드오프 LiveView 등 완료), 잘못된 API 정정(인터럽트 반환 2-튜플,
  `MCP.tools/1`, A2A=`el_graph_web`/Plug·Bandit, `use ElGraph.Agent` 콜백, Signal `:id`),
  미문서 기능 추가(Durability seam, `Ctx.memo`/task_cache, 보안 모델 등). Dialyzer 7개 앱.
- **타입 정확화.** `Checkpoint.next`(엔트리 튜플), `Checkpointer.node_write`(`{update, control}`)
  타입을 실제 형태로 보강; `ElGraph.A2A` moduledoc의 패키지명(`el_graph_a2a`→`el_graph_web`) 정정.

## [0.4.0] — 2026-06-20

적대적 감사(다중 에이전트 차원별 검증)에서 도출한 5개 갭 클로저. 보안 기본값 강화, 성능
주장 입증(벤치마크), 핵심 API 테스트 보강, 문서 정확성. 모든 변경 TDD. 기본 스위트 629
+ DB 어댑터 55(Postgres/Valkey) 통과.

**배포 범위**: 수정이 담긴 형제 앱 `el_graph_web`·`el_graph_ecto`·`el_graph_redis`를 0.4.0으로
**첫 Hex 배포**. 코어 `el_graph`는 published 콘텐츠 변경이 없어 **0.3.0 유지**(형제 앱은
`{:el_graph, "~> 0.3"}`에 의존). 형제 앱의 el_graph 의존성은 `HEX_PUBLISH=1`일 때만 Hex
버전으로, 평소 umbrella 개발에선 `in_umbrella`로 해석된다.

### Security (일부 **breaking**)

- **HTTP 인증 fail-closed (breaking).** `ElGraphWeb.Auth`가 이제 `api_keys`가 미설정/빈
  목록(`nil`/`[]`)이면 모든 요청을 **401로 막는다**(기존: 개방). 인증을 의도적으로 끄려면
  `api_keys: :public`을 명시해야 한다 — 키 누락 실수로 엔드포인트가 열리지 않는다.
  **마이그레이션**: 개방 운영이 필요하면 `server_spec(... api_keys: :public)`을 추가하라.
- **안전 역직렬화(`[:safe]`).** Postgres/Valkey 체크포인터·Store의 모든 `binary_to_term`
  읽기(9곳)가 `[:safe]`를 쓴다 — DB가 변조돼도 새 atom/함수 생성(atom 고갈·RCE 표면)을 막는다.
- **HTTP 본문 크기 제한.** A2A·AG-UI·MCP 라우터에 1 MB `Plug.Parsers` 한도를 둬 멀티 MB
  페이로드로 인한 메모리 고갈(OOM)을 막는다(초과 시 413).

### Added

- **벤치마크 스위트** — `apps/el_graph/bench/`(Benchee): 동시성 스케일링(100→1k→10k 에이전트),
  superstep 처리량, durability 모드 지연, input projection 전/후. 런타임 성능 주장을 검증 가능하게.
- **time-travel/내구성 테스트 보강** — `Executor.resume_from/3` 직접 분기(fork) 테스트,
  3+ 병렬 형제 부분 실패 보존 테스트. 보안 역직렬화 회귀 테스트 4종(PG/Valkey 체크포인터·Store).

### Changed / Docs

- **"durable by default" 정정** — README가 내구 실행을 "기본값"이 아니라 **체크포인터 한 줄로
  켜는 opt-in**으로 정확히 기술한다(`checkpointer: nil`이 실제 기본값).
- **ReqLLM 스트리밍 폴백 문서화** — `ElGraph.LLM.ReqLLM`은 비스트리밍 전용이며
  `stream_supported?/1`로 감지 후 `chat/3` 폴백을 쓰도록 모듈독에 명시.
- **테스트 수치 정정** — SPEC의 오래된 "460" → 현재 기본 629(el_graph 524 + web 52 + trace 47
  + req_llm 6) + DB 어댑터 55.

## [0.3.0] — 2026-06-18

보고서 후속 심화(메모리 영속·관측·내구성+) + 양방향 MCP + 분산 전달 보장. 모든 변경 TDD,
6개 앱 전부 Dialyzer 0 경고. el_graph 521 · el_graph_web 50 테스트 통과.

### Added

- **양방향 MCP** — ElGraph Action을 **MCP 서버**로 노출: `ElGraph.MCP.Server`(순수 JSON-RPC
  dispatch — initialize/tools/resources/prompts), 두 transport `ElGraphWeb.MCP.Router`(Streamable
  HTTP, `/mcp`)·`ElGraph.MCP.Stdio`(CLI, 줄 단위). **MCP 클라이언트** 보강:
  `ElGraph.MCP.Client.StreamableHTTP`(구체 transport + 양방향 `listen/3`),
  `ElGraph.MCP.Client.Capabilities`/`Receiver`(sampling/elicitation/roots 라이브). tools/call 입력 가드레일.
- **메모리 심화** — `Memory.fact_at/4`(시점 T 유효값), `set_fact ... on_conflict:`
  (`:latest`/`:reject`/병합 fn). 교체형 `ElGraph.Memory.Backend`(`Native`/`Mem0`/`Zep`).
- **Store 영속 어댑터** — `ElGraph.Store.Redis`(Valkey, el_graph_redis) +
  `ElGraph.Store.Postgres`(el_graph_ecto). `StoreContract`를 lib로 승격(3백엔드 공유 계약).
- **task 메모이제이션** — `Ctx.memo/3`: LLM/툴 호출을 `{node, key}`로 캐시, 체크포인트 영속
  → 재시도·재개 시 재실행 금지(durability+, Temporal Activity/@task).
- **구조화 출력 재시도** — `ElGraph.LLM.Structured.generate/4`: LLM 출력→스키마 검증→오류
  되먹임 재시도(Instructor/Pydantic AI 패턴).
- **분산 전달 보장** — Signal `id`(CloudEvents) + `ElGraph.Signal.Dedup` + Agent `dedup:` 옵션으로
  at-least-once 멱등 수신(netsplit 재전달 흡수). `:peer` 2노드 `:pg` fan-out 통합 테스트.
- **관측 계측 완성** — 정적 인터럽트 이벤트(`node.interrupt {kind}`) + `[:el_graph, :sensor, :signal]`.
  SPEC §13 "잔여 계측"(checkpoint/Agent/Bus/Sensor/정적 인터럽트) 전부 종료.

### Changed

- **Dialyzer** — `el_graph_otel` 분리로 움브렐라 6개 앱 전부 0 경고.
- **문서** — README 하이라이트에 신규 역량 반영(메모리/분산/MCP/관측), SPEC §11/§13 구현 정합화,
  `Bus.Pg` 분산 운영 가이드(libcluster 호스트 위임).

### Tooling

- **ExDoc** — 루트 `mix docs`로 우산 전체 API 문서 + 가이드/설계 extras 생성. hex 패키지
  메타데이터(`el_graph`: description/licenses/links).

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
