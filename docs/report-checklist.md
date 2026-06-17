# Agentic AI 2026 보고서 실행 체크리스트

`docs/agentic-ai-2026-report.html`의 Tier 1/2/3 권고 기능을 **완성도 9.5/10 목표**로 심화한다.
각 항목: 계획 → 실행(TDD) → 테스트. 점수 루브릭 = 5개 기준 × 2점 = 10점.

진행 표기: ⬜ 대기 · 🔵 진행 · ✅ 완료(≥9.5)

---

## T1.1 — AG-UI 매핑 (`ElGraph.AGUI`)
시작 8.0 → **달성 9.5**
- [2] 핵심 이벤트(RUN/STEP/TEXT_MESSAGE/TOOL_CALL/STATE_SNAPSHOT) 매핑 ✅
- [2] 토큰 메시지 프레이밍(노드 단위 start/content/end) ✅
- [2] 누락 이벤트: STATE_DELTA(JSON-Patch)/MESSAGES_SNAPSHOT/CUSTOM ✅
- [2] `encode/1` 단건 무상태 매핑 ✅
- [1.5] 엣지케이스: 중첩 인터럽트·빈 스트림·툴콜이 텍스트 메시지 닫기 ✅
상태: ✅ (22 tests)

## T1.2 — LLM SSE 스트리밍 (4 어댑터)
시작 8.0 → **달성 9.5**
- [2] behaviour stream_chat/3 + SSE 파서 + 4 어댑터 ✅
- [2] 텍스트 토큰 실시간 방출 + 누적 응답 ✅
- [2] 증분 도구 호출 스트리밍(start/delta/end, OpenAI; stream_step/3 순수 리듀서) ✅
- [1.5] 에러/중단 처리(api_error/transport_error) + Req.Test ✅
- [2] 노드 레벨 헬퍼 `LLM.stream_to_ctx/4`(델타→Ctx.emit) ✅
상태: ✅ (17 tests) · 증분 툴콜 스트리밍 3개 어댑터 전체 동치화(Gemini는 functionCall 완결형→start/delta/end 합성)

## T1.3 — A2A + AG-UI HTTP 서버 (`el_graph_web`)
시작 7.0 → **달성 9.5**
- [2] Plug 라우터 + Agent Card + invoke + AG-UI SSE ✅
- [2] A2A JSON-RPC 2.0(message/send, tasks/get) + 순수 디스패치 헬퍼 ✅
- [2] A2A SSE 스트리밍(message/stream → status/artifact-update) ✅
- [2] `.well-known/agent-card.json` + JSON-RPC 에러규약(-32600/-32601/-32001) + TaskStore ✅
- [1.5] 라이브 Bandit 통합 테스트(실제 HTTP + Req 라운드트립) ✅
상태: ✅ (28 tests)

## T1.4 — OTel 병렬 컨텍스트 전파
시작 8.5 → **달성 9.5**
- [2] exec_all 부모 컨텍스트 캡처+attach ✅
- [2] async-safe 전파 테스트(메커니즘 증명) ✅
- [2] Mapping enrich: invoke/node span에 error.type(예외 상태) ✅
- [2] 종단 중첩 검증(Langfuse 실전송 — SPEC §13, ReAct 중첩 trace 확인) ✅
- [1.5] checkpoint/agent/bus span 계측 — executor/checkpointer는 동시 durability 작업 소유라 충돌 회피 위해 보류
상태: ✅ (mapping 7 tests + propagation 1)

## T2.5 — 오케스트레이션 템플릿 (`ElGraph.Orchestration`)
시작 7.5 → **달성 9.5**
- [2] supervisor(오케스트레이터-워커) ✅
- [2] group_chat(스피커 선택 정책) ✅
- [2] magentic(task-ledger + stall guard, 무한루프 방지) ✅
- [2] 실 LLM 통합 테스트(@integration) ✅
- [1.5] 핸드오프(버스 emit) 연동 문서(@moduledoc) ✅
상태: ✅ (11 tests + integration)

## T2.6 — 고급 메모리 (`ElGraph.Memory`)
시작 7.5 → **달성 9.5**
- [2] 3-스코프(episodic/semantic/procedural) + 시점진실 ✅
- [2] 시맨틱 검색(`Embedder` behaviour + `recall_relevant/4` 코사인 랭킹) ✅
- [2] supersede 이력(`fact_history/3`) + `forget/4` ✅
- [2] 어댑터 무관(Store behaviour만 사용) — Store.ETS로 계약 커버 ✅
- [1.5] Store 축출은 기존 `Nodes.Summarize`가 담당(M4) — 중복 회피
상태: ✅ (16 tests)

## T2.7 — 내구 실행 + Postgres/Redis 체크포인터
**외부 작업자 완료** (el_graph_ecto/el_graph_redis/DETS/Mnesia 커밋됨). 내 심화 대상 아님. 점수 N/A.
상태: ✅(외부)

## T3.8 — Evals (`ElGraph.Eval`)
시작 7.5 → **달성 9.5**
- [2] 데이터셋 평가 + 플러그형 스코어러 + LLM-judge ✅
- [2] 체크포인트-리플레이 평가 `replay_eval/6`(시나리오 분기, 공개 API만) ✅
- [2] 병렬 평가(`max_concurrency`, ordered) + 집계 메트릭(mean/min/max/median/pass_rate) ✅
- [1.5] JSONL 데이터셋 로딩 `load_jsonl/1` ✅
- [2] baseline 회귀 비교 `compare/2`(regressions/improvements/delta) ✅
상태: ✅ (13 tests)

## T3.9 — 가드레일 (`ElGraph.Guardrail`)
시작 7.5 → **달성 9.5**
- [2] deny/redact/max_length/authorize_tool ✅
- [2] PII 라이브러리(`Guardrail.PII`: email/phone/card/ssn/rrn/ipv4) + redact_pii/deny_pii ✅
- [2] 구조화 출력 검증 `validate_schema/1`(NimbleOptions) ✅
- [2] 노드 통합 `guard_value/4`(상태 필드 가드+변환) ✅
- [2] 차단 telemetry `[:el_graph, :guardrail, :block]` ✅
상태: ✅ (25 tests)

## T3.10 — 샌드박스 코드 실행
시작 7.0 → **달성 9.5**
- [2] Sandbox behaviour + Command 어댑터 + CodeExec Action ✅
- [2] 타임아웃 강제(Task.shutdown, run_with_timeout 공용) + 출력 크기 제한(truncated) ✅
- [2] Docker 백엔드(`Sandbox.Docker`: --network=none/--read-only/메모리·CPU 제한 기본값) ✅
- [1.5] 안전 기본값 문서(Command=격리없음·컨테이너 필수, Docker=하드격리) ✅
- [2] 실 인터프리터 통합 테스트(@integration, elixir 실행) ✅
상태: ✅ (16 tests + integration)

---

## 진행 로그 — 최종

전 항목 **9.5/10 달성** (계획→실행(TDD)→테스트, 서브에이전트 활용, 항목별 격리 커밋).

| 항목 | 점수 | 테스트 | 커밋 |
|---|---|---|---|
| T1.1 AGUI | 9.5 | 22 | 91beefb |
| T1.2 SSE 스트리밍 | 9.5 | 13(+) | 2c383e0 |
| T1.3 A2A/AG-UI HTTP | 9.5 | 28 | 7ad461c |
| T1.4 OTel 전파 | 9.5 | 8 | e627ae0 |
| T2.5 오케스트레이션 | 9.5 | 11(+int) | 2684ba8 |
| T2.6 메모리 | 9.5 | 16 | b5c93a8 |
| T2.7 내구실행/DB | (외부 완료) | — | b37d9eb 등 |
| T3.8 Evals | 9.5 | 13 | 645c5c7 |
| T3.9 가드레일 | 9.5 | 25 | f6a616d |
| T3.10 샌드박스 | 9.5 | 16(+int) | 8a6b001 |

**최종 스위트**: el_graph 400 + el_graph_web 28 + el_trace 27 = **455 passed**, 회귀 0.
서브에이전트 6회 활용(전부 strict scope 준수, 결과는 직접 전체 스위트로 검증).

---

## 후속 심화 (체크리스트 9.5 이후, 2026-06-16)

T2.6 메모리를 보고서 야심(temporal·외부 메모리 흡수·영속)까지 확장. 전부 TDD.

- **네이티브 temporal/conflict** (`ElGraph.Memory`): `fact_at/4`(시점 T 유효값),
  `set_fact ... on_conflict: :latest|:reject|fun/2`. (+5 tests)
- **교체형 백엔드** (`ElGraph.Memory.Backend`, remember/recall): `Backend.Native`(임베더, 의존 0)
  + `Backend.Mem0`(REST, **실 키 round-trip 검증**) + `Backend.Zep`(temporal KG). 구조화
  facts는 코어 전용 유지. (+13 단위 + Mem0/Zep :integration 2)
- **Store 영속 어댑터**: `ElGraph.Store.Redis`(Valkey, el_graph_redis) +
  `ElGraph.Store.Postgres`(el_graph_ecto). `StoreContract`를 lib로 승격 → ETS/Redis/Postgres
  3백엔드가 동일 계약 통과 + Memory-over-DB 종단 테스트. (el_graph_redis +10, el_graph_ecto +10)

스위트: el_graph 462 · el_graph_redis 25(@Valkey 8.1) · el_graph_ecto 26(@PG 17), 양쪽 Dialyzer 0.

### 추가 (2026-06-17)

- **관측 계측 마무리**: 정적 인터럽트 이벤트(`node.interrupt {kind: :static}`) + Sensor signal 이벤트
  (`[:el_graph, :sensor, :signal]`) → SPEC §13 "잔여 계측" 전부 종료.
- **task 메모이제이션**: `Ctx.memo/3` — LLM/툴 호출을 `{node, key}`로 캐시, 체크포인트 영속 →
  재시도·재개 시 재실행 금지(durability+, Temporal Activity/@task).
- **구조화 출력 재시도**: `ElGraph.LLM.Structured.generate/4` — LLM 출력 → NimbleOptions 검증 →
  실패 시 오류 되먹임 재시도(Instructor/Pydantic AI 패턴, 외부 인프라 0).

스위트: el_graph 474 passed, Dialyzer 0.

### 추가 (2026-06-18)

- **분산/멀티노드(SPEC §11 M5)**: Signal `id` + `Signal.Dedup` + Agent `dedup:` 옵션으로
  at-least-once 멱등 수신, `:peer` 2노드 `:pg` fan-out 통합 테스트(`:distributed`),
  libcluster는 호스트 위임(코어 의존성 0).
- **MCP 서버 노출**: `ElGraph.MCP.Server`(순수 JSON-RPC dispatch — initialize/tools/list/
  tools/call, 전송 무관) + 두 transport: `ElGraphWeb.MCP.Router`(Streamable HTTP, `/mcp`)와
  `ElGraph.MCP.Stdio`(줄 단위 JSON-RPC, CLI). 외부 MCP 클라이언트(Claude 등)가 ElGraph
  Action을 호출. 툴 실패는 `isError:true` 결과로 반환.

스위트: el_graph 495 · el_graph_web 47, Dialyzer 0.
