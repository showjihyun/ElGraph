# 도그푸딩 로그 — M4(Skill) 추출의 입력

데모 에이전트(`ElGraph.Demo`, 문서 Q&A, 실 OpenAI gpt-4o)를 실제로 굴리며 관찰한 기록.
SPEC §5 원칙: "Skill은 실제 에이전트를 도그푸딩한 후 반복 패턴을 추출해 설계한다 — 미리 추상화하지 않는다."

실행 방법(`apps/el_graph`에서 실행 — 스크립트는 `apps/el_graph/scripts/`에 있다): `mix run scripts/dogfood.exs` (유형별 질문 4종) / `mix run scripts/demo.exs` (대화형)

## 세션 1 (2026-06-13) — 발견과 수정

질문 4유형: 단순 조회 / 다문서 종합 / 비교 / 범위 밖.

| # | 질문 유형 | 1차 결과 | 2차(수정 후) |
|---|---|---|---|
| Q1 | 단순 조회 (보존 정책) | ❌ "찾을 수 없음" — 문서에 있는데 | ✅ 빈도/내구성 옵션 정확 인용 |
| Q2 | 종합 (인터럽트 재실행) | ❌ 동일 | ✅ 재실행 시맨틱 + 카운터 매칭 정확 |
| Q3 | 비교 (LangGraph 대비) | ✅ 근거 기반, 환각 없음 | ✅ |
| Q4 | 범위 밖 (비행기 예약) | ✅ 정직한 거절 | ✅ |

지연: 질문당 2.4~4.9초. introspection: 실행 중 `%{active: [:agent], step: 2}` 관측, 종료 후 `[]` (자동 정리 확인).

### 마찰과 조치

1. **[수정됨] 검색 툴의 멀티워드 질의 실패** — 가장 큰 발견. 전체 질의 문자열 부분일치라
   "체크포인트 보존 정책 옵션"이 0건. **프레임워크가 아니라 툴 품질이 병목**이었다.
   → 단어 토큰화 + any-word 매칭 + 겹친 단어 수 랭킹으로 교체 (테스트 추가, TDD).
2. **[수정됨] LLM이 1회 검색 실패 후 포기** — 시스템 프롬프트에 "비면 더 짧은 키워드로
   1~2회 재검색" 지침 추가. 재검색 전략은 프롬프트의 일부다 — Skill이 시스템 프롬프트를
   포함해야 하는 근거.
3. **[미해결] usage가 버려진다** — `handle_result`가 답변만 추출하고 토큰 사용량을 버림.
   비용 관측 불가. → Skill 설계에 usage 리포팅 포함.
4. **[미해결] thread_id 고정** — 에이전트당 단일 thread라 introspection에서 질문별 run을
   구분 못 함. → M4 설계 질문: 에이전트의 thread 정책(대화당? 요청당?).
5. **[관찰] 부분 정답** — Q1 2차 답변이 빈도/내구성 옵션은 정확히 짚었으나 `keep: {:last, n}`
   (보존 한도)는 누락. 랭킹 상위 20줄 컷의 한계 — 검색 품질은 점진 개선 영역.

## Skill 후보 1호: "Grounded Q&A"

도그푸딩에서 확인된 응집 단위 — 이 묶음이 통째로 재사용된다:

| 구성요소 | 데모에서의 실체 | Skill로 일반화하면 |
|---|---|---|
| 도메인 검색 Action | `DocsSearch` (docs/*.md) | 검색 Action을 파라미터로 주입 |
| 근거 강제 시스템 프롬프트 | "반드시 검색 → 근거 기반 → 비면 재검색 → 없으면 모른다" | Skill이 소유 (재검색 전략 포함 — 마찰 2의 교훈) |
| 시그널 라우트 | `"question.asked"` → `{:run, %{messages: [user(q)]}}` | 라우트 패턴 + 핸들러 |
| 그래프 | `Presets.react(llm, [tool], system:, budget:)` | Skill이 그래프 조각 제공 (서브그래프 합성) |
| 결과 처리 | 마지막 assistant content → reply_to | usage 포함 리포팅으로 확장 (마찰 3) |

가설적 사용 형태 (M4에서 검증할 것 — 지금 구현하지 않는다):

    use ElGraph.Agent, skills: [
      {ElGraph.Skills.GroundedQA, tool: MyApp.WikiSearch, route: "question.*"}
    ]

## 세션 2 (2026-06-13) — 대화 맥락 / 동시 부하 / 2호 에이전트

실행: `mix run scripts/dogfood2.exs` (실 OpenAI). 두 번째 에이전트 `SummarizeAgent`
(툴 없는 단일 변환) 추가 — Grounded Q&A와 대비할 두 번째 표본.

### 관찰 결과

| 관찰 | 결과 |
|---|---|
| 대화 맥락 유지 | 🔶 **불명확** — "방금 설명한 그 보존 정책" 질문에 `keep: :all`/`keep: {:last, n}`를 정확히 답했으나, 직전 답변엔 보존 정책이 없었다. 맥락 누적이 아니라 "보존 정책" 키워드로 **재검색**해 맞춘 것으로 추정. 즉 맥락 유지 여부가 동작으로 구분되지 않는다. |
| RateLimiter (limit 2, 동시 5) | ✅ **정확히 동작** — 획득 시점 `[0, 0, 305, 305, 615]ms`. 2개 즉시·2개 300ms·1개 600ms. `with_limit`의 모니터 기반 회수 정상. |
| SummarizeAgent (2호) | ✅ 단일 LLM 변환 정상, 툴 루프 없음 (LLM 1회 호출 단언). |

### 마찰 (세션 2 신규)

6. **[중요] RateLimiter가 LLM 호출 경로에 연결돼 있지 않다** — 데모 트리에 limiter가
   있지만(`__MODULE__.Limiter`), ReAct의 `agent` 노드가 `acquire`를 부르지 않는다.
   limiter 자체는 완벽히 동작하나(관찰 2) **아무도 쓰지 않는다**. LLM 어댑터 호출을
   limiter로 감싸는 지점이 빠졌다. → Skill/프리셋이 limiter 연동을 떠안아야 한다.
7. **대화 맥락 정책 부재** — thread_id 고정인데 연속 질문이 누적되는지 매번 새 실행인지
   불명확(마찰 4의 구체화). 멀티턴 대화 에이전트면 thread=대화, 단발 작업이면 thread=요청.
   현재는 둘 사이에 끼어 어느 쪽도 명확히 지원 못 함.

## Skill 후보 2호와 공통 추상화

2호 "Transform"(SummarizeAgent)을 1호 "Grounded Q&A"와 비교하니 **공통 골격이 드러난다**:

| 측면 | 1호 Grounded Q&A | 2호 Transform | 공통화 |
|---|---|---|---|
| 시그널 라우트 | `"question.asked"` → messages | `"text.submitted"` → messages | **라우트 패턴 + 입력 매퍼** |
| 그래프 | `react(llm, [DocsSearch], system, budget)` | `react(llm, [], system, budget)` | **react 프리셋 (툴 0~N개)** |
| 시스템 프롬프트 | 근거 강제 + 재검색 전략 | 변환 지시 | **Skill이 소유** |
| 결과 처리 | 마지막 assistant → reply_to | 동일 | **결과 매퍼 (+ usage, 마찰 3)** |
| LLM | 주입 | 주입 | 주입 |

→ **두 표본의 차이는 (툴 목록, 시스템 프롬프트, 라우트 패턴, 입출력 매퍼) 4개 파라미터뿐**이고
나머지(react 그래프, 비블로킹 실행, 직렬 큐, crash-only, 결과 리포팅)는 동일하다.
이것이 M4 Skill의 형태다 — 특화된 에이전트가 아니라 **"시그널 구동 ReAct Skill"**:

    use ElGraph.Agent, skills: [
      {ElGraph.Skills.SignalReAct,
        route: "question.*", tools: [MyApp.WikiSearch],
        system: "...", reply: :messages_last}
    ]

후보가 2개가 됐고 공통 골격이 4-파라미터로 수렴했다 → **M4 Skill 추출 착수 조건 충족.**
단, 착수 전 마찰 6(limiter 연동)·7(thread 정책)을 먼저 해소해야 Skill이 이를 흡수할 수 있다.

## 세션 3 (2026-06-13) — 마찰 6·7 해소

선결 마찰 두 건을 TDD로 수정하고 데모에 연결, 실 OpenAI로 재검증.

### 마찰 6 — RateLimiter ↔ LLM 호출 연동

`Presets.react(llm, tools, rate_limiter: limiter)` 추가 — agent 노드의 모든 LLM 호출이
`RateLimiter.with_limit/2`를 통과한다. 테스트로 고정: limiter 슬롯을 미리 점유하면 실행이
블록되고, 슬롯이 풀리면(모니터 회수) 진행. 데모 트리의 limiter가 이제 실제 호출 경로에 연결됐다.

### 마찰 7 — thread 정책 명시

에이전트 `:thread` 옵션:

| 값 | 의미 | 검증 |
|---|---|---|
| `:per_request` (기본) | 매 시그널이 빈 상태에서 시작 (무상태 작업) | 연속 2회 → count 1, 1 |
| `{:fixed, id}` | 이전 최종 상태를 이어받아 누적 (대화), checkpointer 필수 | 연속 2회 → count 1, 2 |

구현: executor에 `:initial_state` 옵션(defaults 대신 이전 대화 상태에서 시작), 서버가 fixed일 때
최종 상태를 `conv_state`로 보관·주입. crash 시 checkpointer에서 conv_state 복원(crash-only).
데모는 `{:fixed, "demo-conversation"}`로 전환 — 이제 연속 질문이 한 대화에 결정적으로 누적된다
(세션 2의 "맥락 유지 불명확"이 명시적 동작으로 해소).

### 재검증 (세션 3)

3관찰 모두 정상: 대화 누적 동작(맥락+재검색 병행), RateLimiter `[0,0,306,306,612]ms` 유지,
SummarizeAgent 정상. 테스트 160개 통과.

## 남은 마찰 (M4로 이월)

- **마찰 3** — usage가 결과에서 버려진다 (handle_result가 content만 추출). Skill의 결과 매퍼에 포함.
- **마찰 5** — 검색 상위 20줄 컷으로 부분 정답. 검색 품질 점진 개선(M4 범위 아님).

## 세션 4 (2026-06-13) — Sensor (도그푸딩 3호)

`ElGraph.Sensor` 프리미티브(폴링 + `tick/1` 수동 트리거) 추가. 도그푸딩 3호로
`DocsWatch` 센서(docs/ 총 크기 변경 감지) → "docs.changed" 시그널 →
SummarizeAgent로 연결한 **Sensor→Agent 체인**을 실 OpenAI로 관찰.

### 관찰 결과 (`scripts/dogfood3.exs`)

- ✅ 체인 동작: 센서 tick → 변경 감지 → 시그널 → 요약 에이전트 → "0바이트→55142바이트로
  변경" 요약 (tokens 65/21).
- ✅ 변화 없을 때 조용함: 두 번째 tick은 발화 안 함 (poll 상태가 실제 크기로 갱신됨).

### 발견

8. **시그널 변환을 인라인 함수로 떼웠다** — 센서는 "docs.changed"를 내는데 요약 에이전트는
   "text.submitted"를 받는다. 스크립트에서 `forward` 클로저로 변환·전달했다. **시그널
   라우터/버스(SPEC §5 SignalTransport)가 없어서** 센서-에이전트 타입이 다르면 손으로 잇는다.
   → 이것이 다음 프리미티브(Signal 라우터/버스)의 필요 근거. 여러 에이전트로의 fan-out,
   타입 변환, 구독이 버스의 일.
9. **Sensor는 Skill 후보가 아니다** — Agent 3종(Q&A/요약/센서연동)과 달리 Sensor는
   "환경→시그널"이라 ReAct 골격과 무관. SignalReAct Skill과 별개 축. 즉 M4의 Skill 추상화는
   Agent에만 해당하고 Sensor는 독립 프리미티브로 둔다 (현재 설계가 맞음).

### Sensor 패턴 관찰 (Skill화 보류)

센서 표본이 1개(DocsWatch)뿐이라 공통 패턴 추출은 이르다. "폴링 + 이전값 비교 + 변화시
발화"가 흔할 것으로 보이나(임계 감시, 큐 길이, 파일 변경 등), 표본 2~3개 전엔 추상화하지
않는다 — 세션 1의 교훈(Action 검색 품질이 진짜 병목이었듯, 성급한 추상화는 빗나간다).

## 세션 5 (2026-06-13) — Signal Bus (발견 8 해소)

`ElGraph.Signal.Bus` 추가 — 패턴 구독 + fan-out 발행, Registry 기반(구독자 죽으면 자동 정리).
구독 2형태: `subscribe/2`(Agent 자기 구독 → send_signal), `subscribe/3`(함수 구독 → 변환/로깅).
Agent에 `:subscribe` 옵션 통합(init에서 자기 구독).

### 발견 8 해소 검증 (`scripts/dogfood4.exs`, 실 OpenAI)

세션 3에서 센서→에이전트를 인라인 클로저로 손수 이었던 것을 버스로 디커플링:

    DocsWatch --("docs.changed")--> Bus --[변환 함수 구독]--> ("text.submitted") --> SummarizeAgent

- 센서: 버스에 **발행만** (대상을 모른다)
- 에이전트: 버스에서 **자기 타입("text.submitted")만 구독** (소스를 모른다)
- 변환: 버스의 함수 구독이 담당 (타입 변환은 라우팅과 분리)

✅ 체인 동작: tick → 발행 → 변환 → 요약 ("0→57025바이트 증가", tokens 57/21).
**센서와 에이전트가 서로를 전혀 모른다** — 발견 8의 "손으로 잇기"가 구조적으로 사라졌다.

### 관찰

10. **버스가 L4(멀티 에이전트)의 기반이 된다** — fan-out(한 시그널 → N 에이전트), 타입 변환,
    구독이 전부 버스의 일. 핸드오프(`:command, :handoff`)도 버스 발행으로 자연스럽게 표현된다.
    분산은 transport 어댑터(:pg/PubSub) 교체로 — 현재 Registry 기반이 로컬 기본.
11. **함수 구독이 발행자 컨텍스트에서 실행됨** — 무거운 변환이면 발행자를 블록. 현재는
    가벼운 변환만 상정. 비동기 dispatch는 필요해지면(표본 나오면) 추가. 지금은 YAGNI.

## 세션 6 (2026-06-13) — Store 장기기억 + 요약 압축 (M4)

`ElGraph.Nodes.Summarize`(컨텍스트 압축)와 `ElGraph.Store`(thread를 넘는 장기 기억)를
실 OpenAI로 연결해 관찰. 긴 대화를 만들고 임계 초과 시 오래된 메시지를 LLM 요약으로
치환하면서, 축출된 원문이 Store에 보관되는지 확인하는 것이 목적.

### 구현 / 시연 (`scripts/dogfood5.exs`, 실 OpenAI)

- 14턴 대화를 시뮬레이션하고 `Summarize.run`에 `trigger: {:messages, 10}`,
  `keep: {:messages, 6}`, `store: {Store, config, namespace}` 옵션 전달.
- 압축 결과는 append `{:replace}` 마커로 반환: `[요약 1] + [최근 6]` = 7개 메시지로 수렴
  (오래된 8개는 LLM 요약 1건으로 치환).
- 축출된 8개 원문은 Store 네임스페이스(`["conversations", "demo"]`)에 보관 — `Store.list/2`로
  확인. SPEC §4(요약 노드)·§6(Store) 설계가 실데이터로 검증됨(SPEC M4 "요약+Store 모두 실
  OpenAI 검증"의 근거).

### 관찰

- **요약은 압축이자 인덱싱** — 단기 컨텍스트는 요약본으로 가볍게 유지하되, 원문은
  Store에 남아 thread를 넘어 다시 조회 가능. 체크포인트(단기)와 Store(장기)의 역할 분리가
  동작으로 확인됨. trigger 미달이면 압축하지 않고 원본 그대로 통과(불필요한 LLM 호출 회피).
  (새 마찰 없음 — 마찰 카운터 13건 유지.)

## 세션 7 (2026-06-13) — 멀티 에이전트 (M5: 핸드오프 / :pg / A2A)

M5 코어 3종을 TDD로 구현하고 멀티 에이전트 파이프라인을 실 OpenAI로 관찰.

### 구현

- **핸드오프**: SignalReAct `:emit` 옵션 — 결과를 시그널로 버스에 발행. reply_to(직접)와
  병행. 2-에이전트 파이프라인(Researcher --research.done--> Bus --> Summarizer)이 빌딩 블록.
- **:pg transport**: `Bus.Pg` — 버스 이름이 `:pg` scope. Agent 구독은 클러스터 분산,
  함수 구독은 거부(fun은 노드 경계를 못 넘음). `transport: :pg` 옵션으로 교체.
- **A2A 매핑**: `A2A` 순수 함수 — Task 상태(`:ok`→completed, `:interrupted`→input-required 등),
  Agent Card(tools→skills), Message 변환. HTTP 서버는 `el_graph_a2a` 패키지 몫.

### 관찰 (`scripts/dogfood6.exs`, 실 OpenAI)

- ✅ 파이프라인 메커니즘 동작: Researcher → 버스 → Summarizer → 사용자.
  **두 에이전트가 서로를 전혀 모른다** (버스 emit/subscribe로만 연결). 핸드오프 성립.
- 🔶 품질 관찰: Researcher가 "인터럽트" 검색에서 근거를 못 찾았다고 답함(문서엔 풍부한데).
  단일 검색 후 보수적 종료 경향 — 메커니즘이 아니라 검색/프롬프트 품질 문제(세션 1·5의
  검색 품질 마찰의 연장). 메커니즘 검증이 목적이므로 통과로 본다.

### 발견

12. **파이프라인 각 단계의 품질이 곱해진다** — Researcher 출력이 부실하면 Summarizer도
    부실. 멀티 에이전트는 약한 고리가 전체를 좌우. → 단계별 검증(중간 시그널 관찰)이
    introspection의 역할. usage가 단계마다 reply에 실려 비용 추적 가능(마찰 3 해소가 여기서 빛남).
13. **A2A/분산은 순수 매핑 + 얇은 어댑터로 분리가 옳다** — Task 상태 매핑은 M1 프리미티브와
    1:1이라 순수 함수로 충분했고, HTTP 서버는 별도 패키지로 미룸. "BEAM이라 분산이 공짜"는
    아니지만(SPEC R2), 핸드오프·fan-out·라우팅은 버스로 거의 공짜였다.

## 세션 8 (2026-06-14) — Langfuse 관찰 → ElTrace 차별점 도출

OTel 브리지로 다양한 실행 패턴을 self-host Langfuse에 보내고(`scripts/otel_observe.exs`),
API로 trace를 조회해 "Langfuse가 잘 보여주는 것 / 못 보여주는 것"을 데이터로 관찰했다.

### Langfuse가 잘 하는 것 (재구현 불필요)

- **단일 그래프 trace**: invoke_workflow(SPAN) → node(TOOL) → chat(GENERATION, model·토큰 정확).
  완벽하다. ElTrace가 흉내 낼 이유 없음.
- **thread_id → sessionId 매핑**: `gen_ai.conversation.id`를 Langfuse sessionId로 인식.
  HITL의 invoke/resume 두 trace가 같은 session(`hitl-...`)으로 묶여 나란히 보인다.

### Langfuse가 못 하는 것 (= ElTrace 차별점, 전부 데이터로 확인)

| # | 관찰된 한계 | ElGraph가 아는 것 | ElTrace 차별점 |
|---|---|---|---|
| 1 | **인터럽트가 trace에 안 보임** — 멈춘 invoke(0aed)는 그냥 "agent까지 있고 끝난 짧은 trace". *왜* 멈췄는지(HITL 대기, before=[:tools], payload) 정보 없음 | 체크포인트에 `interrupted`/`payload`/`next` 보유 | "여기서 HITL 대기 중, 질문=…" 명시 + 승인 UI |
| 2 | **invoke↔resume 인과 없음** — session으로 나란히 놓일 뿐, "0aed에서 멈춘 게 128f에서 이어졌다"는 연결이 trace 구조에 없음 | 체크포인트 체인(같은 thread의 step 연속) | thread 전체 생애(invoke→interrupt→resume…)를 하나의 타임라인으로 |
| 3 | **멀티 에이전트 핸드오프 끊김** — Researcher(session 906)와 Summarizer(778)가 무관한 별도 trace. 파이프라인이 연결 안 됨 | 버스 시그널의 source/type 인과("research.done을 누가 내고 누가 받았나") | 에이전트 간 핸드오프 그래프 |
| 4 | **time-travel 불가** — trace를 *보여줄* 뿐, 그 상태로 되감아 재개 못 함 | 체크포인트 = 임의 step의 완전한 상태 | trace의 어느 step에서든 "여기서 재개" |

### 결론 — ElTrace의 정체성이 데이터로 확정됨

4가지가 전부 **"ElGraph가 체크포인트·버스로 아는 인과를 Langfuse는 모른다"**로 수렴한다.
즉 ElTrace = **ElGraph의 도메인 지식(체크포인트 체인, 시그널 인과, 재개 가능성)을 활용한 관측** —
범용 trace 뷰어(Langfuse)와 경쟁하는 게 아니라, BEAM 내장 + 체크포인트 통합으로 보완.

**방침 확정**: Langfuse를 기본 trace 백엔드로 유지(OTLP). ElTrace는 위 4개 차별점만 만든다.
범용 span/generation/토큰 시각화는 Langfuse에 위임 — 재구현 비목표. 우선순위는 #1(인터럽트
가시성)·#2(thread 생애 타임라인)가 높다 — 둘 다 체크포인트로 이미 데이터가 있어 작다.

**작은 선행 보강 후보**(ElTrace 없이도 가치): Bridge가 `[:el_graph, :node, :interrupt]` 실행
이벤트를 OTel span event로 추가하면 #1의 일부(인터럽트 발생 표시)가 Langfuse에서도 보인다.
단 invoke↔resume 인과(#2)·핸드오프(#3)는 여전히 ElTrace 영역.

## M4 착수 준비 완료

Skill 후보 2개 + 공통 4-파라미터 골격 + 선결 마찰(6·7) 해소. 다음:
`ElGraph.Skills.SignalReAct` 추출 — `route` / `tools` / `system` / `reply`(+ usage) 파라미터,
내부에 react(rate_limiter 연동) + thread 정책 흡수.
