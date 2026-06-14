# ElGraph 생태계 검토 & 적용 제안 (2026-06)

> AI 에이전트 프레임워크 생태계(Elixir + 범용 OSS)를 웹에서 다시 조사해 장단점을 정리하고,
> ElGraph에 **추가로 적용할 만한 사항**과 **아키텍처 변경안**을 우선순위로 제안한다.
> 조사 시점 2026-06, 1차 출처(GitHub/공식 문서/엔지니어링 블로그) 기반. 출처는 §7.

관련 문서: 설계 [`SPEC.md`](SPEC.md) · LangGraph 대비 [`elixir-vs-python-comparison.md`](elixir-vs-python-comparison.md)

---

## 0. TL;DR

**결론**: ElGraph의 핵심 베팅(BEAM 위 graph-first + 내구 실행 + HITL + 실시간 관측 UI)은 생태계에서
**구조적으로 비어 있는 자리**다 — Elixir 진영에 이 조합을 갖춘 성숙한 패키지가 없다. 다만 "durable"을
표방하는 것에 비해 **체크포인터가 ETS(휘발성) 하나뿐**인 점이 가장 큰 약점이다. 아래 P0를 닫으면
README의 LangGraph 비교가 마케팅이 아니라 사실이 된다.

| 우선순위 | 항목 | 한 줄 | 아키텍처 영향 |
|---|---|---|---|
| **P0** | 내구 체크포인터 백엔드 (Postgres/Mnesia) | ETS는 노드 재시작 시 소실 → "durable" 주장과 모순 | 신규 앱 `el_graph_ecto` (behaviour는 이미 존재) |
| **P0** | OTel GenAI semconv 마감 | 이미 `gen_ai.*` 방출 중 — 표준 최신화만 | 단일 모듈 수정 |
| **P1** | LLM 토큰 스트리밍 (SSE) | 현재 미구현(SPEC 명시), LiveView와 시너지 | LLM 어댑터 + `stream/3` 모드 |
| **P1** | 구조화 출력 노드 (검증+재시도) | Instructor/Pydantic 패턴 — 노드 간 타입 계약 | `el_graph` 내 신규 노드 헬퍼 |
| **P1** | 장기 기억 + 시맨틱 검색 | Store에 임베딩/벡터 검색 behaviour | Store behaviour 확장 |
| **P1** | MCP 완성 (Streamable HTTP, sampling/elicitation, 서버) | client 일부만 — 양방향·서버 노출 | `el_graph` MCP + 신규 서버 |
| **P2** | A2A HTTP 서버 (`el_graph_a2a`) | 매핑만 있음 — Task 생명주기=체크포인터 | 신규 앱 (SPEC 예정) |
| **P2** | 앱 분리 (`el_graph_otel`/`el_graph_a2a`/`el_graph_ecto`) | 의존성 격리 (코어 의존성 0 유지) | 우산 재구성 |
| **P2** | durability 모드 + task 메모이제이션 | LLM 호출을 replay 아닌 캐시 재생 | 실행기 옵션 |
| **P2** | trajectory 캡처 → 회귀 테스트 | Replay/introspection 위에 얹기 | 테스트 키트 |
| **P3** | HITL 인자 편집(approve/edit/reject), 미들웨어, 서빙 API | 운영 성숙도 | 점진 |

---

## 1. ElGraph 현재 위치 (검토 기준선)

추천을 현실에 묶기 위해, 지금 **이미 있는 것**을 명확히 한다(코드 확인 기준):

- **그래프 코어**: 상태 채널/reducer, 조건부 엣지, 병렬 fan-out(`:send`), `:command`, 서브그래프, `max_steps`. 실행은 **superstep(Pregel-유사) 루프** — LangGraph의 BSP 모델과 동일 계열.
- **체크포인트**: `ElGraph.Checkpointer` **behaviour(플러그블)** + **ETS 어댑터 1개**. 보존 정책(`keep:`), 부분 실패 superstep의 **pending writes 보존**(성공분 재실행 안 함).
- **HITL**: `interrupt_before` + 동적 `Ctx.interrupt` → `{:interrupted, …}`, `resume: value`로 재개, `interrupt_info` 보존.
- **time-travel**: `ElTrace.Replay.from/5` — 과거 step에서 새 thread로 fork, 원본 보존.
- **에이전트**: GenServer 에이전트(직렬 큐·crash-only 복구), Signal Bus(로컬/`:pg`), Sensor, Store(ETS KV), RateLimiter, Runner introspection + `stream/3`(생애 이벤트).
- **LLM/툴**: OpenAI/Anthropic/Gemini 어댑터(Req), Action(스키마→검증+tool spec), **MCP 클라이언트**(전송 추상), ReAct 프리셋, 비용 가드.
- **상호운용/관측**: **A2A 순수 매핑**(Task 상태/Agent Card/Message), **OTel 브리지**(이미 `gen_ai.*` semconv 방출), telemetry 전면 계측.
- **el_trace**: Timeline·Replay·Sessions·Telemetry→PubSub·LiveView UI, 공개 API `ElTrace.observe/fork/timeline`.

**구조적 우위(조사로 재확인)**: "graph-first 작성 + 내구 실행 + 체크포인트 + HITL + 관측 UI"를 한 패키지로 가진
성숙한 Elixir 라이브러리는 **없다**(Jido는 에이전트 중심, Sagents는 대화 중심, magus/Command는 작고 미검증).
또한 Temporal이 별도 서비스 계층으로 푸는 "크래시 복구·재실행"을 BEAM은 **OTP(슈퍼바이저+프로세스)로 네이티브** 제공한다.
→ ElGraph는 이 빈자리를 메우기에 런타임적으로 유리하다.

---

## 2. 생태계 스냅샷

### 2.1 Elixir AI/에이전트 프레임워크

| 프로젝트 | 무엇 | 강점 | ElGraph가 배울 점 |
|---|---|---|---|
| **Jido** (~1.7k★) | OTP-네이티브 에이전트 | Action/Directive/Signal 분리, **AI-optional 코어**, 1만 에이전트@~25KB | **효과(effect)를 선언적 directive로** 분리 → 체크포인트/HITL이 쉬워짐. 코어를 LLM 비의존으로 |
| **Sagents** (~227★) | OTP 에이전트 + HITL | **per-tool approve/reject/edit-args**, 체크포인트 behaviour, Horde 클러스터, LiveView 디버거 | HITL을 "일시정지 상태"로 1급 모델링, **인자 편집**, 미들웨어 파이프라인 |
| **brainlid/langchain** (~1.2k★) | LLM 상호작용 표준 | 폭넓은 프로바이더, 스트리밍, **trajectory 평가** | **trajectory 캡처 → 회귀 테스트** 픽스처 |
| **Ash AI** (~178★) | 선언적 LLM 툴박스 | **리소스 인가가 툴에 상속**(secure by construction), pgvector RAG, MCP 서버 | **툴 경계의 권한 게이트**, pgvector 임베딩 |
| **Instructor / InstructorLite** | 구조화 출력 | **Ecto changeset 검증 + 오류 피드백 재시도** | 구조화 출력 노드의 **검증·자기수정 루프** |
| **Bumblebee/Nx/Axon** (~1.6k★) | 모델 서빙 | `Nx.Serving` 자동 배치·분산 | (임베딩 자가호스팅 옵션) |
| **ReqLLM / ExLLM / Hermes MCP** | 전송/프로토콜 | 통합 스트리밍 클라이언트, MCP client+server | MCP 전송 레퍼런스 |

요지: Elixir 생태계는 **LLM 상호작용(langchain)·구조화 출력(Instructor)·선언 RAG(Ash)** 는 강하지만,
**graph-first 내구 오케스트레이션**은 비어 있다. Sagents가 HITL/체크포인트/UI에서 가장 가깝지만 대화 중심.

### 2.2 범용 OSS 에이전트 프레임워크 (LangGraph 중심)

| 프레임워크 | 모델 | 베낄 만한 것 |
|---|---|---|
| **LangGraph** (~35k★) | 그래프/Pregel super-step | **체크포인터 백엔드(SQLite/Postgres/Redis)**, thread_id+namespace, **다중 스트리밍 모드**, **BaseStore+시맨틱 검색**, `interrupt()`/`Command(resume)`, **time-travel(get_state_history/fork)**, **durability 모드(exit/async/sync)+@task 메모이제이션**, Agent Server(cron·background·double-texting) |
| **AutoGen→MAF / AG2** (~60k★) | 이벤트/액터 → 그래프 | 핸드오프, 멀티에이전트 팀, OTel. (단, 잦은 대규모 마이그레이션은 반면교사) |
| **CrewAI** (~50k★) | 역할 크루 + Flow | 역할 기반 + YAML, 통합 메모리. (크래시 재개는 약함) |
| **OpenAI Agents SDK** (~27k★) | 에이전트+핸드오프 | **핸드오프=`transfer_to_*` 툴**, 가드레일, 세션, 기본 트레이싱, **durability는 Temporal에 위임** |
| **LlamaIndex Workflows** (~50k) | 이벤트 step | Context 직렬화 체크포인트, HITL 이벤트, **DBOS 플러그블 durability** |
| **Pydantic AI** (~18k★) | 타입 Agent + DI | **검증된 구조화 출력+재시도**, **durable 통합 폭(Temporal/DBOS/Prefect/Restate)**, pydantic-evals |
| **DSPy** (~35k★) | 시그니처+컴파일 | 옵티마이저(MIPROv2/GEPA) — 프롬프트 자동 최적화(별개 영역) |
| **Mastra** (TS, ~25k★) | step 그래프 | **스냅샷 suspend/resume + 플러그블 스토리지 어댑터**(LangGraph 패턴의 TS 검증) |

요지: **패턴은 LangGraph로 수렴** — (1) 플러그블 체크포인터, (2) reducer 채널+super-step, (3) interrupt/resume HITL,
(4) time-travel, (5) 다중 스트리밍 모드, (6) cross-thread 메모리+시맨틱 검색, (7) OTel 트레이싱. ElGraph는 (2)(3)(4)는
이미 보유, (1)은 부분(behaviour만), (5)(6)은 미흡, (7)은 양호.

### 2.3 내구 실행 / 관측 / 프로토콜

- **내구 실행(Temporal/Restate/Inngest/DBOS)**: 공통 교훈 — *완료된 step을 durable 저장 후 replay/memoize*. **LLM 호출은 비결정적이므로 "한 번 기록, replay 시 재실행 금지"**(Activity/step로 감쌈). **DBOS**(Postgres 라이브러리, 클러스터 불필요)가 가장 낮은 마찰의 모델. 핵심: *in-memory journaling만으론 durable이 아니다* → **2계층(핫 캐시 + durable 백킹)**.
- **관측(OTel GenAI semconv)**: 사실상 표준으로 수렴. 핵심 속성 `gen_ai.operation.name`(chat/execute_tool/invoke_agent/invoke_workflow), `gen_ai.provider.name`, `gen_ai.request|response.model`, `gen_ai.usage.input|output_tokens`, `gen_ai.response.finish_reasons`, 메트릭 `gen_ai.client.operation.duration`·`token.usage`. MCP 스팬(`mcp.*`)은 **W3C Trace Context 전파**로 에이전트↔서버 trace를 하나로 묶는다. (스펙은 아직 *Development* — 버전 핀 권장.)
- **프로토콜**: **MCP** 공식 전송은 **stdio + Streamable HTTP** 둘로 정리(구 HTTP+SSE 폐기). 서버 기능(tools/resources/prompts) 외 **클라이언트 기능(sampling/elicitation/roots)** 이 자주 누락됨 — sampling=서버가 LLM 실행 요청, elicitation=HITL. **A2A**(Linux Foundation, v1.0)는 Agent Card + Task 생명주기(`SUBMITTED→WORKING→INPUT_REQUIRED→COMPLETED…`) + SSE/푸시.

---

## 3. 갭 분석 — ElGraph에 없는/약한 것

| # | 갭 | 현재 | 업계 표준 | 심각도 |
|---|---|---|---|---|
| G1 | **durable 체크포인터** | ETS만(휘발성) | LangGraph Postgres/SQLite, DBOS Postgres, Mastra 어댑터 | **높음** — "durable" 주장과 직결 |
| G2 | **LLM 토큰 스트리밍** | 없음(SPEC 명시) | 전 프레임워크 표준 | 높음 — LiveView 가치 미회수 |
| G3 | **시맨틱 메모리/벡터** | Store=ETS KV | LangGraph BaseStore 시맨틱, Ash pgvector, CrewAI | 중 |
| G4 | **구조화 출력 검증 루프** | tool 스키마 검증만 | Instructor/Pydantic 재시도 | 중 |
| G5 | **MCP 완성도** | client(전송 추상)만 | Streamable HTTP, sampling/elicitation, **서버** | 중 |
| G6 | **A2A HTTP 서버** | 순수 매핑만 | A2A v1.0 Task/SSE/푸시 | 중(전략) |
| G7 | **durability 모드/task 메모이제이션** | pending writes 보존(부분) | exit/async/sync + @task | 중 |
| G8 | **앱 분리** | OTel/A2A가 코어에 in-repo | — | 중(위생) |
| G9 | **HITL 인자 편집** | resume 값 주입만 | Sagents approve/edit/reject | 낮음 |
| G10 | **OTel semconv 최신화** | `gen_ai.*` 방출(양호) | provider.name·finish_reasons·메트릭·MCP trace 전파 | 낮음(마감) |
| G11 | **trajectory 회귀 테스트** | Replay/introspection | langchain Elixir trajectory eval | 낮음 |

---

## 4. 추천 (우선순위별)

각 항목: **무엇 / 왜 / Elixir 구현 / 아키텍처 영향 / 노력**.

### P0-1. 내구 체크포인터 백엔드 (Postgres + Mnesia/DETS)
- **왜**: ETS는 노드/VM 재시작 시 전부 소실 → ElGraph의 핵심 가치("내구 실행")가 실제론 in-memory. 내구 실행 4종(Temporal/Restate/Inngest/DBOS)의 공통 교훈: *in-memory journaling은 durable이 아니다*.
- **구현**: `Checkpointer` behaviour는 **이미 플러그블** → 어댑터만 추가.
  - **2계층 패턴**(DBOS/Restate): ETS = 핫 materialized 캐시, 뒤에 durable 백킹. **step 결과가 관측되기 전에 durable write 완료** 불변식을 지킨다.
  - **`el_graph_ecto`**(신규 앱): `Ecto`/Postgres 어댑터 — 행=체크포인트, `(thread_id, step)` 키. DBOS식 "비즈니스 데이터+체크포인트 동일 Postgres 트랜잭션"이면 exactly-once에 근접.
  - **BEAM 네이티브 옵션**: `Mnesia`(disk_copies) 또는 `DETS` 어댑터 — 외부 의존성 0 유지(코어 철학과 합치). 인프라 없이 디스크 내구.
- **아키텍처**: 신규 앱 `el_graph_ecto`(Postgres) + 코어에 `Checkpointer.Mnesia`/`.Dets`. 코어 의존성 0 불변.
- **노력**: 중~상. **가장 가치 큰 변화**.

### P0-2. OTel GenAI semconv 마감 (이미 대부분 됨)
- **왜**: 브리지가 이미 `gen_ai.operation.name`/`usage.*`/`conversation.id`를 방출 → Langfuse/Phoenix/Datadog가 추가 어댑터 0으로 수집. 표준 최신화만 하면 끝.
- **구현(단일 모듈 `otel/mapping.ex`)**: `gen_ai.system` → **`gen_ai.provider.name`** 보강, `gen_ai.response.finish_reasons` 추가, 표준 **메트릭 2종**(`operation.duration`/`token.usage`) 방출, MCP 호출에 **W3C Trace Context 전파**(`mcp.*` 속성)로 에이전트↔서버 trace 결합. 콘텐츠 캡처는 플래그로 기본 off(프라이버시).
- **아키텍처**: 영향 없음(매핑 한 모듈). 스펙이 *Development*이므로 버전 핀 + 격리.
- **노력**: 하. 빠른 승리.

### P1-1. LLM 토큰 스트리밍 (SSE) + 그래프 스트리밍 모드
- **왜**: SPEC가 미구현으로 명시. LiveView 실시간 UI(ElTrace)의 가치가 토큰 스트리밍 없이는 절반.
- **구현**: LLM 어댑터에 Req `into:`(SSE) 스트리밍 추가 → `Ctx.emit`로 토큰 방출. `stream/3`를 LangGraph식 **모드**로 정리: `:updates`(상태 델타) / `:messages`(토큰, 노드·태그 메타) / `:custom`(사용자 진행). 서브그래프는 namespace 태깅.
- **아키텍처**: 코어 LLM/Runner 내부. el_trace는 토픽 구독만 추가.
- **노력**: 중.

### P1-2. 구조화 출력 노드 (검증 + 자기수정 재시도)
- **왜**: 노드 간 신뢰 가능한 타입 계약 = 가장 reliable한 step 결합(Pydantic AI/Instructor/Atomic Agents 공통). ElGraph는 Action 스키마 검증은 있으나 **LLM 출력→검증→오류 피드백 재시도** 루프가 없음.
- **구현**: `ElGraph.LLM.structured/3`(또는 노드 헬퍼) — 스키마(NimbleOptions 또는 Ecto changeset) → LLM 호출 → 검증 실패 시 **오류 메시지를 모델에 되먹여 재시도**(max_retries). InstructorLite의 "magic-free" 노선 권장.
- **아키텍처**: 코어 내 헬퍼. 영향 작음.
- **노력**: 중.

### P1-3. 장기 기억 + 시맨틱 검색 (Store 확장)
- **왜**: 체크포인트(thread 상태)와 **별개**의 cross-thread 지식 계층 필요. LangGraph BaseStore+시맨틱, Ash pgvector, CrewAI 메모리가 표준화.
- **구현**: `Store` behaviour에 `search(namespace, query, opts)` 추가 + **임베딩 어댑터**(behaviour). 1차는 **API 임베딩**(OpenAI 등, 코어 의존성 0 유지) → 코사인. Postgres 채택 시 **pgvector**(`el_graph_ecto`에). 네임스페이스 계층(`{"memories", user_id}`).
- **아키텍처**: Store behaviour 확장 + 선택적 pgvector(el_graph_ecto).
- **노력**: 중.

### P1-4. MCP 완성 (Streamable HTTP + 클라이언트 기능 + 서버)
- **왜**: 현재 client는 전송 추상만. 업계는 **stdio + Streamable HTTP** 둘로 수렴; **sampling/elicitation/roots**는 자주 누락 → 차별점. 또 ElGraph Action을 **MCP 서버로 노출**하면 외부 에이전트가 ElGraph 툴을 사용.
- **구현**: 전송 2종(`Port` stdio / Plug 단일 엔드포인트+SSE). **sampling = 서버가 LLM 노드 실행 요청**(ElGraph가 대신 실행), **elicitation = HITL interrupt 노드**, **roots = 샌드박스 설정**. 서버는 Phoenix 라우트(el_trace 또는 신규). 연결당 GenServer.
- **아키텍처**: 코어 MCP 확장 + 선택적 서버(웹 계층).
- **노력**: 중~상.

### P2-1. A2A HTTP 서버 (`el_graph_a2a`)
- **왜**: 매핑은 이미 있음. A2A **Task 생명주기 = 내구 task의 상태머신** → ElGraph 체크포인터가 그대로 추적. `INPUT_REQUIRED`=interrupt/resume, Artifacts=그래프 출력. P0-1(durable 체크포인터)이 깔리면 **푸시 알림(장기 task 완료 통지)** 이 자연스럽다.
- **구현**: 신규 앱(Phoenix). Agent Card를 그래프 정의에서 생성(skills=엔트리 그래프), `/.well-known/` 노출. JSON-RPC/REST + SSE.
- **아키텍처**: 신규 앱(SPEC 예정). P0-1에 의존.
- **노력**: 상.

### P2-2. 앱 분리 (`el_graph_otel` / `el_graph_a2a` / `el_graph_ecto`)
- **왜**: 코어 런타임 의존성 0 철학 유지 — OTel(opentelemetry_*), Ecto/Postgres, Phoenix를 코어에서 떼어내 **선택적 앱**으로. (SPEC가 이미 `el_graph_otel`/`el_graph_a2a` 분리 예정으로 명시.)
- **구현**: 우산에 앱 추가, 코어 `mix.exs`에서 opentelemetry 의존성 제거 → `el_graph_otel`로.
- **아키텍처**: 우산 재구성. 기존 `el_trace` 분리 패턴 재사용.
- **노력**: 중.

### P2-3. durability 모드 + task 메모이제이션
- **왜**: 부분 실패 시 pending writes 보존은 이미 있음 → 한 걸음 더: **LLM/툴 호출을 "한 번 기록, replay 시 재실행 금지"**(Temporal Activity/LangGraph @task). 비용·중복 부작용 차단.
- **구현**: 노드 결과를 `(run_id, node_id, attempt)` 키로 체크포인트에 기록 → 재개 시 완료 노드는 **재생**. `durability: :exit | :async | :sync` 옵션으로 성능↔내구 트레이드오프.
- **아키텍처**: 실행기 옵션 + 체크포인터(P0-1) 활용.
- **노력**: 중.

### P2-4. trajectory 캡처 → 회귀 테스트
- **왜**: 실행의 결정/툴호출 trajectory를 기록하면 (a) 관측 타임라인 + (b) **회귀 픽스처**(저장 trajectory replay → 라우팅 동일성 단언). langchain Elixir가 검증한 패턴, ElGraph Replay/introspection과 자연 결합.
- **구현**: Runner에 trajectory 수집 옵션 + `ElGraph.Test`에 replay-assert 헬퍼.
- **노력**: 하~중.

### P3 (점진적 성숙도)
- **HITL 인자 편집**: resume를 값 주입뿐 아니라 **툴 인자 편집(approve/edit/reject)** 까지(Sagents). el_trace UI에 편집 폼.
- **미들웨어 파이프라인**(Sagents): 노드 전후 합성 가능한 behaviour(레이트리밋·리댁션·트레이싱). 단 ElGraph는 retry/timeout/telemetry가 이미 있어 ROI 검토 후.
- **서빙 계층**: 백그라운드 run·cron(Jido Cron 참고)·**double-texting 전략**(reject/queue/interrupt/rollback) — GenServer 에이전트의 직렬 큐에 자연 매핑.
- **툴 경계 인가**(Ash AI): 툴이 실제 작업을 감싸면 정책 게이트.

---

## 5. 아키텍처 변경 제안 (종합)

```
ElGraph/ (umbrella)
├─ apps/
│  ├─ el_graph/          # 코어 — 의존성 0 유지 (telemetry만)
│  │   └─ Checkpointer.{ETS, Mnesia, Dets}   # ← BEAM 네이티브 durable (신규)
│  ├─ el_trace/          # 관측 UI (기존)
│  ├─ el_graph_ecto/     # ← Postgres 체크포인터 + pgvector 메모리 (신규, P0-1/P1-3)
│  ├─ el_graph_otel/     # ← OTel 브리지 분리 (신규, P2-2 / SPEC 예정)
│  └─ el_graph_a2a/      # ← A2A HTTP 서버 (신규, P2-1 / SPEC 예정)
```

원칙(유지): **코어 `el_graph`는 외부 런타임 의존성 0**. durable·관측·프로토콜·웹은 전부 **선택적 형제 앱**.
이는 README가 강조한 "공급망 표면적 최소" 우위를 지키면서 기능을 확장하는 길이다.

핵심 설계 불변식(내구 실행 조사에서):
1. **2계층 체크포인트** — ETS(핫) + durable 백킹. *step 결과 관측 전에 durable write 완료*.
2. **LLM/툴 호출은 journal-once** — replay 시 재실행 금지(비용·중복 부작용 차단).
3. **A2A Task = 체크포인터 상태머신** — 별도 워크플로 엔진 재구현 금지, OTP+체크포인터로 충분.

---

## 6. 제안 로드맵 (단계)

1. **마일스톤 A — "진짜 durable"**: P0-1(Mnesia/DETS 먼저 → Postgres `el_graph_ecto`) + P0-2(OTel 마감). 끝나면 README의 durable·관측 주장이 사실로 확정.
2. **마일스톤 B — "에이전트 UX"**: P1-1(스트리밍) + P1-2(구조화 출력) + P1-3(시맨틱 메모리). ElTrace 토큰 스트리밍까지.
3. **마일스톤 C — "상호운용"**: P1-4(MCP 완성) + P2-1(A2A 서버) + P2-2(앱 분리).
4. **마일스톤 D — "운영 성숙"**: P2-3(durability 모드) + P2-4(trajectory eval) + P3 선택.

각 단계는 기존 TDD 규약(red→green→refactor, async) 준수. 체크포인터 어댑터는 기존 `store_contract`/`checkpointer_contract`
**공유 계약 테스트** 재사용.

---

## 7. 출처 (조사 2026-06)

**Elixir**: Jido github.com/agentjido/jido · Sagents github.com/sagents-ai/sagents · brainlid/langchain github.com/brainlid/langchain · Ash AI github.com/ash-project/ash_ai · Instructor github.com/thmsmlr/instructor_ex · InstructorLite github.com/martosaur/instructor_lite · Bumblebee github.com/elixir-nx/bumblebee · ReqLLM github.com/agentjido/req_llm · Hermes MCP github.com/cloudwalk/hermes-mcp · awesome-elixir-llm-genai

**OSS 프레임워크**: LangGraph docs.langchain.com/oss/python/langgraph (persistence·streaming·interrupts·time-travel·durable-execution) · AutoGen/MAF learn.microsoft.com/agent-framework · CrewAI docs.crewai.com · OpenAI Agents SDK openai.github.io/openai-agents-python · LlamaIndex Workflows developers.llamaindex.ai · Pydantic AI pydantic.dev/docs/ai · DSPy dspy.ai · Semantic Kernel→MAF · Haystack docs.haystack.deepset.ai · Mastra mastra.ai

**내구 실행/관측/프로토콜**: Temporal temporal.io/blog · Restate docs.restate.dev · Inngest inngest.com · DBOS · OTel GenAI semconv (opentelemetry.io/blog/2026/genai-observability, greptime.com OTel GenAI) · Langfuse langfuse.com/integrations/native/opentelemetry · OpenLLMetry traceloop.com · MCP modelcontextprotocol.io/specification + blog.modelcontextprotocol.io (transport future) · A2A a2a-protocol.org + github.com/a2aproject/A2A

> 정확도 주의: ★ 수치는 2026-06 라이브 페이지의 자릿수 근사. OTel GenAI semconv는 *Development* 단계(버전 변동) — 속성명은 신뢰, 정확한 버전은 핀 권장. 세부 출처 URL은 각 조사 스트림 원문 참조.
