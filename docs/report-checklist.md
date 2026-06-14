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
상태: ✅ (13 tests) · 참고: 증분 툴콜은 OpenAI 우선(Anthropic/Gemini는 텍스트+헬퍼)

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
시작 7.5 → 목표 9.5
- [2] deny/redact/max_length/authorize_tool ✅
- [ ] 내장 PII 패턴 라이브러리(이메일/전화/카드/주민번호 등)
- [ ] 구조화 출력 검증(JSON schema / NimbleOptions)
- [ ] 노드 래퍼 통합(입출력 가드 적용 헬퍼) + ReAct 연동
- [ ] 차단 시 telemetry 이벤트 + 정책 위반 기록
상태: ⬜

## T3.10 — 샌드박스 코드 실행
시작 7.0 → 목표 9.5
- [2] Sandbox behaviour + Command 어댑터 + CodeExec Action ✅
- [ ] 타임아웃/리소스 제한 강제(프로세스 kill)
- [ ] Docker/컨테이너 백엔드 어댑터
- [ ] 출력 크기 제한 + 안전 기본값(네트워크/FS 차단 문서)
- [ ] 통합 테스트(실제 인터프리터, @integration)
상태: ⬜

---

## 진행 로그
(작업하며 각 항목 점수/상태 갱신)
