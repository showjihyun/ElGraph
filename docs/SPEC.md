# ElGraph 스펙

> Python 의존성 없는 Elixir 네이티브 그래프 기반 에이전트 프레임워크.
> L1(그래프 실행기)은 LangGraph 대체, L1~L4 전체는 Jido 수준의 에이전트 프레임워크를 목표로 한다.

상태: v0.9 (설계 검토 R1~R5 반영, M1~M4 완료 · M5 코어 완료) · 2026-06-13

**구현 현황 요약**: 테스트 460개(el_graph 403 + el_graph_web 28 + el_trace 29) + 통합 다수(실 OpenAI 등), 전부 `async: true`. 코어(L1) 런타임
의존성 `:telemetry` 1개. 실 OpenAI로 도는 문서 Q&A 에이전트, 센서→버스→에이전트 체인,
2-에이전트 파이프라인이 동작 검증됨. 구현 로드맵·완료 기준은 §8, 실사용 관찰은 `DOGFOODING.md`.

---

## 1. 포지셔닝과 설계 원칙

**정체성: graph-first 에이전트 프레임워크.** Jido(액션/시그널 중심)와 달리 그래프 오케스트레이션이 코어 자산이며, 에이전트 런타임은 그 위에 쌓는다.

기존 Elixir 생태계와의 구분 (2026-06 조사): **Agens**는 LangChain/CrewAI 영감의 초기 단계(v0.1.x) 라이브러리로 GenServer 중심 멀티 에이전트 잡 흐름이고, **brainlid/langchain**은 LLM 통합/체인이지 그래프 실행기가 아니다. **버전 있는 체크포인트·pending writes·HITL·동적 fan-out을 갖춘 충실한 LangGraph 급 그래프 실행기는 Elixir에 없다** — 이것이 L1의 존재 이유. brainlid/langchain은 경쟁자가 아니라 L2 LLM 어댑터 후보로 재사용을 검토한다.

| 원칙 | 내용 |
|---|---|
| 의존성 최소화 | 코어(L1)의 런타임 의존성은 `:telemetry` 1개 (Elixir 1.18+ 내장 `JSON` 사용, telemetry는 M1 계측 요구와의 트레이드오프로 수용). L2부터 NimbleOptions, Req 등 최소 추가 |
| Functional core, imperative shell | 그래프 정의·실행 루프는 순수 함수. 부수효과(LLM 호출, 체크포인트 영속화)는 behaviour 뒤로 |
| 의존성 역전만 차용 | 클린아키텍처의 계층 구조는 도입하지 않는다. behaviour 기반 포트/어댑터(Checkpointer, Store, SignalTransport)만 차용 |
| 프로세스는 런타임 이유가 있을 때만 | 노드는 순수 함수, 실행기는 호출(invocation)당 프로세스 1개. 노드별 GenServer 금지 |
| 라이브러리는 슈퍼비전 트리를 소유하지 않는다 | ElGraph는 전역 프로세스를 자동 시작하지 않는다. 모든 프로세스(Task.Supervisor, Agent, Registry)는 `child_spec`으로 제공하고 호스트 앱 트리에 마운트 |
| 계층별 패키지 분리 가능 | 의존 방향: L4 → L3 → L2 → L1 → OTP. 역방향 참조 금지 |
| 제어 흐름은 언어에 위임 | 그래프 추상화는 영속성·관측·병렬·재개가 필요한 지점에만 쓴다. 단순 분기/반복은 Elixir의 패턴 매칭·재귀가 이미 잘한다 — LangGraph처럼 언어 제어 흐름을 프레임워크로 재구현하지 않는다 (부록 A-3) |
| 운영 기능은 전부 오픈 코어에 | 백그라운드 내구 실행, HITL, 체크포인트, 관측(telemetry/introspection)을 유료 플랫폼 없이 코어가 제공한다. LangGraph Platform 류의 상위 유료 계층을 전제한 기능 구멍을 만들지 않는다 (부록 A-5) |

## 2. 계층 아키텍처

```
L4  el_graph_swarm     멀티 에이전트: 핸드오프, 분산(:pg), 전달 보장
L3  el_graph_agent     에이전트 런타임: 장수명 프로세스, 시그널, 스킬, 센서
L2  el_graph_action    액션/툴: 스키마 검증, LLM tool 스펙 생성, retry, MCP 어댑터
L1  el_graph           그래프 실행기 (코어)
L0  OTP                프로세스, 슈퍼비전, Registry, pg
```

---

## 3. L1 — 그래프 실행기 (코어)

### 3.1 State (채널/Reducer)

상태는 키별 reducer를 가진 맵. reducer 미지정 키는 overwrite.

```elixir
graph =
  ElGraph.new()
  |> ElGraph.state(:messages, default: [], reducer: {ElGraph.Reducers, :append, []})
  |> ElGraph.state(:result, default: nil)
```

- **Reducer는 MFA 튜플 또는 원격 캡처(`&Mod.fun/2`)만 허용.** 로컬 익명 함수는 코드 리로드/재배포 후 재개 시 `badfun`으로 깨지므로 compile 시점에 거부한다(§3.8 직렬화 참조).
- 자주 쓰는 reducer는 `ElGraph.Reducers`에 내장: `append/2`, `merge/2`, `add/2`.
- 컨텍스트 압축 1단계로 `append_trim/3`(append 후 최근 n개만 유지 — 순수 함수, M2)을 제공한다. 토큰 기반 요약 압축은 LLM이 필요하므로 L2(§4).

### 3.2 Node

```elixir
@type node_fun :: {module(), atom(), [term()]} | (state :: map(), ctx :: ElGraph.Ctx.t() -> node_return())

@type node_return ::
        %{optional(atom()) => term()}                    # 상태 부분 업데이트
        | {:command, goto :: atom() | :end, update :: map()}  # 업데이트 + 다음 행선지 직접 지정
        | [{:send, node :: atom(), input :: map()}]      # 동적 fan-out (map-reduce)
```

- **시그니처는 `(state, ctx)` 2-인자로 처음부터 고정한다.** `ctx`는 thread_id, step, 이벤트 방출, 동적 인터럽트, 취소 확인의 통로. 1-인자 시그니처로 시작하면 이후 모든 사용자 노드를 깨는 마이그레이션이 필요해진다.
- **반환 계약에 `:command`/`:send` 자리를 v0.1부터 예약한다.** 실행기 구현은 M2로 미뤄도 되지만(M1은 받으면 명시적 에러), 계약을 예약해두면 공개 API가 깨지지 않는다.
- durable 그래프(체크포인트 재개를 쓰는 그래프)의 노드는 MFA 권장. 익명 함수 노드는 허용하되 `compile/2` 시 경고.

`ElGraph.Ctx` 공개 API:

```elixir
Ctx.emit(ctx, event)           # 스트리밍 이벤트 방출 (러너에게 메시지 전송)
Ctx.interrupt(ctx, payload)    # 동적 인터럽트 (§3.6)
Ctx.cancelled?(ctx)            # 협조적 취소 확인 — 긴 루프/스트림 처리 중 주기적으로 확인
ctx.thread_id, ctx.step, ctx.node
```

### 3.3 Edge

```elixir
|> ElGraph.add_edge(:tools, :agent)                          # 고정 엣지
|> ElGraph.add_conditional_edge(:agent, {Router, :route, []}) # (state) -> node | :end
```

`compile/2`에서 검증: 끊긴 엣지, 도달 불가 노드, entry 존재, reducer 함수 형태(MFA/원격 캡처).

라우터 함수는 **순수해야 한다**(상태만 보고 결정, 부수효과 금지) — 재개·리플레이 시 재평가되기 때문. 문서로 강제한다.

### 3.4 Executor (superstep 루프)

Pregel/BSP 모델. 한 superstep = 활성 노드 실행 → 쓰기 수집 → reducer 병합 → 다음 노드 결정.

- 실행기 자체는 **순수 함수형 재귀 루프** (`ElGraph.Executor`). 부수효과는 콜백(체크포인터, 이벤트 싱크)으로 주입.
- 호출 단위 실행은 `ElGraph.Runner`가 프로세스 1개(Task)로 감싼다. 수만 개 동시 실행은 BEAM 스케줄러가 처리.
- **러너 소유권**: `invoke/3`·`stream/3`은 호출자에 link(호출자가 죽으면 실행도 정리 — 고아 실행 방지). L3 에이전트처럼 실행 실패를 직접 다루려는 소유자는 `start_run/3`(nolink + monitor)을 사용.
- **실행 introspection (부록 A-1)**: 러너는 Registry에 thread_id로 등록되고, `Runner.list/1`(실행 중 thread 목록)과 `Runner.peek/2`(현재 step/활성 노드/상태 요약)를 제공한다. `:observer`·`:sys`와 함께 "지금 이 에이전트가 뭘 하고 있나"를 외부 관측 플랫폼 없이 운영 중에 답할 수 있게 한다. M3.
- 같은 superstep의 병렬 노드는 `Task.Supervisor.async_stream_nolink`로 fan-out (`max_concurrency` 옵션). Task.Supervisor는 호스트 앱이 마운트한 것을 옵션으로 받는다.
- **안전장치:**
  - `max_steps` 기본값 25. 초과 시 `{:error, {:max_steps_exceeded, state}}`.
  - **병렬 쓰기 충돌은 런타임 병합 시 검출.** 같은 superstep에서 reducer 없는 키에 2개 이상 노드가 쓰면 즉시 명확한 에러. (조건부 엣지/Send 때문에 compile 타임 완전 검증은 불가능 — 명백한 정적 케이스만 compile 경고.)
  - 노드별 타임아웃 옵션: `add_node(:slow, fun, timeout: 30_000)`.
- **상태 복사 비용 완화 (input projection)**: 병렬 fan-out은 메시지 복사이므로 큰 상태(긴 대화 히스토리)가 브랜치 수만큼 복사된다. 64바이트 초과 바이너리는 refc로 공유되어 실비용이 줄지만, `add_node(:x, fun, input: [:messages])`로 필요한 키만 전달하는 옵션을 제공한다. 미지정 시 전체 상태 전달.

### 3.5 체크포인트

```elixir
defmodule ElGraph.Checkpointer do
  @callback put(config, Checkpoint.t()) :: :ok | {:error, term()}
  @callback get(config, thread_id, :latest | step) :: {:ok, Checkpoint.t()} | :not_found
  @callback put_writes(config, thread_id, step, [{node, update}]) :: :ok | {:error, term()}  # pending writes
  @callback get_writes(config, thread_id, step) :: [{node, update}]
  @callback list(config, thread_id) :: [%{step: step, version: pos_integer()}]
end
```

`Checkpoint.step`은 "다음에 실행할 superstep"을 뜻하고 `next: []`가 완료를 뜻한다.
어댑터 적합성은 공유 계약 테스트(`ElGraph.CheckpointerContract`)로 검증한다 — 새 어댑터(Postgres 등)는 `use`만 하면 동일 계약을 통과해야 한다.

체크포인트 스키마(처음부터 동결되는 두 가지):

1. **`version` 필드** — 이후 스키마는 마이그레이션으로 진화 가능. 버전 없는 스키마가 진짜 잠금이다.
2. **pending writes** — superstep 내 개별 노드의 완료된 쓰기를 노드 단위로 기록. 병렬 노드 3개 중 2개 성공·1개 실패 후 재개 시, 성공한 노드의 LLM 호출을 재실행하지 않는다.

체크포인트에는 **상태만 저장하고 그래프 정의는 저장하지 않는다.** 재개 시 그래프는 항상 코드에서 재구성(`graph_id`로 매칭). 함수 참조 직렬화 문제를 원천 차단한다.

정책 옵션:

- 보존: `keep: :all | {:last, n}` — 매 스텝 전체 상태 스냅샷은 긴 thread에서 저장소를 비대화시킨다(LangGraph의 알려진 운영 부담, 부록 A-6). `{:last, n}`이면 어댑터가 오래된 체크포인트(와 해당 step의 pending writes)를 정리한다. **전 백엔드(ETS·DETS·Mnesia·Postgres·Redis) 구현 완료.**
- durability(영속 *시점*): `durability: :sync | :async | :exit` (invoke/resume 옵션, **구현됨**). 잦은 체크포인트의 쓰기 증폭은 이 옵션으로 대응한다(별도 빈도 옵션은 미도입).
  - `:sync`(기본) — 매 step 동기 영속. 강한 보장, 기존 동작과 동일.
  - `:async` — 실행당 순서보장 writer 프로세스에 적재(FIFO 메일박스, 반환 전 flush). 크래시 시 마지막 step 유실 가능. writer는 실행기에 link되어 스텝 순서를 보존한다.
  - `:exit` — 매 step 저장을 건너뛰고 **완료(finalize)·인터럽트만 강제 영속**(가장 빠름, 중간 크래시 복구 불가 — 빈도 옵션의 "interrupts_only" 의도를 대체).
  - 인터럽트(정적/동적)는 모드와 무관하게 항상 동기 영속한다. `:async`는 인터럽트 기록 전에 writer를 flush해 같은 step의 비인터럽트 쓰기에 덮이지 않게 한다.

기본 구현 `ElGraph.Checkpointer.ETS`:

- **인스턴스별 테이블** (named table 싱글턴 금지) — 사용자의 `async: true` 테스트가 충돌하지 않는다. 테이블 소유 프로세스의 `child_spec` 제공, config로 테이블 참조 전달.
- 내구 백엔드(**구현 완료**): BEAM 내장 `Checkpointer.DETS`·`.Mnesia`(코어, 외부 인프라 0)와 별도 앱 `el_graph_ecto`(Postgres)·`el_graph_redis`(Valkey/Redis). DB 어댑터의 체크포인터 호출은 실행기 Task에서 직접 수행(커넥션 풀) — 단일 GenServer로 직렬화하지 않는다. 직렬화는 `:erlang.term_to_binary/1`(bytea/RESP).

### 3.6 인터럽트 / Human-in-the-loop

- **정적**: `invoke(graph, input, interrupt_before: [:tools])` — 해당 노드 진입 전에 체크포인트 후 `{:interrupted, ref, state}` 반환.
- **동적**: 노드 내부에서 `Ctx.interrupt(ctx, %{question: "..."})`.
  - 구현: `throw`로 비국소 탈출. 단, 노드는 병렬 Task 안에서 실행되므로 **uncaught throw는 Task exit(`{:nocatch, _}`)으로 변질된다** — 노드 실행 래퍼가 Task 내부에서 catch하여 태그된 정상 반환(`{:__interrupt__, payload}`)으로 변환하고, 실행기는 이를 받아 체크포인트 후 `{:interrupted, ref, payload}`를 반환한다. throw는 실행기 내부에 완전히 캡슐화된다.
  - **병렬 형제 노드**: 같은 superstep의 다른 노드가 인터럽트하더라도 나머지 노드는 완료까지 실행하고, 그 쓰기를 pending writes로 보존한 뒤 인터럽트를 반환한다(재개 시 재실행 방지).
  - **다중 인터럽트 매칭**: 한 노드에 `interrupt` 호출이 여러 개일 수 있으므로 resume 값은 호출 순서 카운터로 매칭한다. 따라서 **노드 내 interrupt 호출 순서는 결정적이어야 한다**(상태에만 의존, 난수/시간 분기 금지).
  - **재개 시맨틱(문서화 필수)**: `resume(graph, ref, value)`는 인터럽트한 노드를 **처음부터 재실행**하고, `Ctx.interrupt/2`는 이번에는 주입된 `value`를 반환한다. 따라서 노드 안에서 interrupt 호출 이전의 부수효과는 중복 실행된다 — interrupt는 노드 초반에 두거나 노드를 분리하라는 가이드 제공.

### 3.7 스트리밍 / 이벤트

- `Ctx.emit/2`와 실행기 생명주기 이벤트(`:node_start`, `:node_end`, `:state_update`, `:checkpoint`)를 러너가 구독자 pid로 전송. `stream/3`은 이를 `Stream.resource`로 감싸 lazy 스트림 제공.
- 백프레셔: 토큰 스트리밍은 네트워크가 상한이므로 기본 무제한 메일박스로 충분. 단, 구독자가 죽으면 이벤트 전송을 멈추도록 러너가 구독자를 모니터링한다.
- `:telemetry` 이벤트는 **M1부터** 심는다(`[:el_graph, :node, :start | :stop | :exception]` 등). 나중에 넣기 가장 고통스러운 부분.
- **OTel GenAI 정렬 (R5)**: `:telemetry` 이벤트는 Elixir 표준을 유지하고, 선택 패키지 `el_graph_otel`(M3)이 OpenTelemetry GenAI 시맨틱 규약 span으로 변환한다. 매핑 방침 — L1 invoke → `invoke_workflow`, L2 Action 실행 → `execute_tool`, L3 에이전트 호출 → `invoke_agent`, `thread_id` → `gen_ai.conversation.id`, LLM 어댑터 토큰 집계 → `gen_ai.usage.input_tokens|output_tokens`. M2/M3에서 메타데이터 필드를 정할 때 이 매핑과 충돌하지 않게 한다.

### 3.8 직렬화

- 기본 ETF(`:erlang.term_to_binary`). 상태에 pid/ref/로컬 fun이 들어오면 체크포인트 시점에 **명시적 에러** (조용한 저장 후 깨진 재개보다 낫다).
- JSON 인코더는 선택 어댑터(외부 시스템에서 체크포인트를 읽어야 할 때).

### 3.9 취소

- `Runner.cancel(ref)` → 협조적 취소: ctx에 취소 플래그 전파, 진행 중 노드는 `Ctx.cancelled?/1`로 확인 가능. 유예시간(`:cancel_timeout`, 기본 5초) 후 Task brutal kill.
- HTTP 진행 중인 노드(LLM 호출)는 Task 종료 시 Req/Finch가 커넥션을 정리하므로 좀비 요청은 남지 않는다.

### 3.10 서브그래프

컴파일된 그래프는 그 자체로 노드가 될 수 있다: `add_node(:research, subgraph)`. 그래프 모델에 v0.1부터 자리 확보(노드 타입에 `:subgraph` 변형), 실행 지원은 M2.

---

## 4. L2 — Action / Tool

```elixir
defmodule MyApp.SearchAction do
  use ElGraph.Action,
    name: "web_search",
    description: "웹을 검색합니다",
    schema: [query: [type: :string, required: true]]

  @impl true
  def run(params, context), do: {:ok, %{results: ...}}

  @impl true  # 선택
  def compensate(params, error, context), do: :ok
end
```

- 스키마 하나(NimbleOptions)에서 **파라미터 검증 + LLM tool-calling JSON 스펙을 동시 생성.**
- Action → 그래프 노드 어댑터 제공 (`ElGraph.Action.to_node/1`).
- **retry 정책**: `add_node(:agent, fun, retry: [max: 3, backoff: :exponential, retry_on: [ElGraph.LLM.RateLimitError]])`. compensate보다 사용 빈도가 높으므로 코어 옵션.
- **MCP 어댑터**: MCP 서버의 툴을 Action으로 자동 변환(`ElGraph.MCP.actions(client)`). 자체 액션 생태계를 처음부터 만들 필요를 없앤다. MCP 클라이언트는 기존 라이브러리(hermes_mcp 등) 어댑터로.
- LLM 클라이언트는 behaviour(`ElGraph.LLM`)로만 정의. 코어는 LLM을 모른다. 기본 어댑터(Anthropic/OpenAI, Req + SSE 스트리밍)는 별도 패키지 `el_graph_llm`.
- **비용 가드 (부록 A-4)**: `max_steps`(스텝 폭주)와 별도로 LLM 어댑터 수준의 토큰/비용 예산 — `budget: [tokens: n]` 초과 시 에러가 아니라 **동적 인터럽트**로 전환해 사람이 계속/중단을 결정하게 한다. 루프 폭주로 인한 토큰 비용 증폭은 LangGraph의 알려진 운영 사고 유형이다. M2.
- **컨텍스트 압축 — 요약 노드 (R5)**: 긴 대화 히스토리의 context rot 대응. 트리거(`tokens:`)·유지(`keep:`)·요약 모델의 3축 옵션을 가진 `SummarizeNode` 헬퍼 — 임계 초과 시 오래된 메시지를 LLM 요약으로 치환(living summary)하고, 축출된 원문은 장기 메모리 Store(§6)로 보낼 수 있다. 개수 기반 trim은 L1 reducer(§3.1). M4.

## 5. L3 — Agent 런타임

```elixir
defmodule MyApp.ResearchAgent do
  use ElGraph.Agent,
    graph: MyApp.ResearchGraph,
    state: [findings: [type: {:list, :map}, default: []]],
    skills: [ElGraph.Skills.Memory]
end
```

- **에이전트 = 그래프 + 영속 상태 + 메일박스를 가진 GenServer.** (프로세스 정당성: 호출 간 지속 상태 + 장애 격리 — Iron Law 통과.)
- **GenServer 콜백 안에서 그래프를 동기 실행하지 않는다.** 실행은 `Task.Supervisor.async_nolink`로 띄우고 결과는 `handle_info`로 수신 — 실행 중에도 시그널(취소 포함) 수신 가능, 실행 크래시가 에이전트를 죽이지 않는다.
- 에이전트 상태는 체크포인터에 영속화 — 프로세스는 crash-only로 설계, 재시작 시 체크포인트에서 복구.
- **Signal**: CloudEvents 필드(type, source, subject, data)를 가진 struct. 라우팅(`"task.*"` 패턴 → 핸들러)만 직접 구현. 전송은 behaviour(`SignalTransport`) — 로컬 Registry dispatch 기본, Phoenix.PubSub/`:pg` 어댑터.
- 이름 등록: `{:via, Registry, {reg, agent_id}}`. 동적 atom 생성 금지.
- 다수 에이전트: DynamicSupervisor(+ 필요시 PartitionSupervisor).
- **전역 rate limiting**: LLM 프로바이더별 동시성 제한(세마포어). 에이전트 50개가 동시에 같은 API를 때리는 상황의 필수 장치.
- Sensor는 시그널을 쏘는 GenServer의 behaviour 래퍼 — 우선순위 낮음(M4).
- Skill은 (액션 묶음 + 시그널 라우트 + 상태 네임스페이스 + 서브그래프)의 컴포지션. **실제 에이전트 2~3개를 도그푸딩한 후 패턴을 추출하여 설계한다(M4). 미리 추상화하지 않는다.**

## 6. L4 — 멀티 에이전트 / 분산

- 핸드오프: 노드가 `{:command, :handoff, %{to: agent_id, ...}}` 반환 → 시그널 전송.
- **오케스트레이션 패턴 템플릿 (R5, M5)**: supervisor(오케스트레이터-워커), magentic(task ledger 기반 동적 에이전트 선택), group chat(스피커 선택 정책)을 미리 조립된 그래프 템플릿으로 제공한다. 빌딩 블록은 서브그래프(§3.10)와 `:command` 핸드오프 — 신규 추상화 없음. sequential/concurrent/map-reduce는 L1이 이미 표현하므로 템플릿 불필요.
- **A2A 어댑터 (R5, `el_graph_a2a`, M5)**: Linux Foundation A2A 프로토콜로 조직 경계 밖 에이전트와 상호운용. MCP가 에이전트↔툴이라면 A2A는 에이전트↔에이전트. Agent Card 발행 + REST/JSON-RPC 바인딩 + SSE를 Phoenix/Req로 구현(gRPC 바인딩은 후순위). Task 생명주기가 기존 프리미티브에 1:1 매핑되므로 얇은 계층이다:

| A2A Task 상태 | ElGraph 대응 (M1 구현 완료) |
|---|---|
| SUBMITTED / WORKING | `Runner.start_run` |
| INPUT_REQUIRED | 동적 인터럽트 `{:interrupted, payload}` → `resume(resume: value)` |
| COMPLETED / FAILED | `{:ok, state}` / `{:error, reason}` |
| CANCELED | `Runner.cancel` |
| 스트리밍 (SSE) | `ElGraph.stream` |
| contextId | `thread_id` |
- 장기 메모리: thread를 넘는 기억을 위한 `ElGraph.Store` behaviour (KV + 시맨틱 검색 선택). 체크포인터(단기)와 분리.
- 분산은 **공짜가 아니다**: `:pg` 메시지는 best-effort — 시그널은 at-least-once + 멱등 수신으로 설계, netsplit 시 Registry 중복 등록 처리, 클러스터 형성은 libcluster에 위임. M5의 명시적 설계 항목.

## 7. 테스트 키트 (`ElGraph.Test`, M2)

- LLM/Action mock 헬퍼(Mox 호환), 그래프 step 단위 전진 헬퍼, 체크포인트 assertion.
- 모든 내장 구성요소는 `async: true` 테스트와 호환(전역 상태 없음 — §3.5 ETS 인스턴스별 테이블).

## 8. 로드맵

| 마일스톤 | 범위 | 완료 기준 |
|---|---|---|
| **M1 코어** ✅ 완료 (2026-06-12) | 그래프 빌더+compile 검증, superstep 실행기, 병렬 fan-out, ETS 체크포인터(pending writes, 버전 스키마), 정적/동적 인터럽트(+값 주입), 스트리밍, 취소, max_steps, 노드별 timeout, 런타임 쓰기충돌 검출, telemetry. `:command`/`:send`/서브그래프는 **계약만 예약** | 충족: 테스트 58개(전부 async) 통과, 커버리지 91.6%, 의존성 `:telemetry` 1개 |
| **M2 Action** ✅ 완료 (2026-06-12) | Action behaviour+스키마, LLM tool 스펙 생성, retry, MCP 어댑터, `:send`/`:command`/서브그래프 실행, ScriptedLLM(테스트 키트), LLM behaviour + Anthropic/OpenAI/Gemini 어댑터(우선 in-repo, hex 분리는 출시 시점 재평가 — SSE 스트리밍은 미구현), 체크포인트 보존 정책(`keep:`), 토큰/비용 예산 가드, `append_trim` reducer, ReAct 프리셋 | 충족: ReAct + map-reduce 예제가 테스트로 동작, 130 테스트 통과 |
| **M3 Agent** ✅ 완료 (2026-06-13) | GenServer 에이전트(비블로킹 실행, 직렬 큐, crash-only 자동 재개), Signal+패턴 매칭, Registry 주소화/child_specs, rate limiter(모니터 기반 자동 회수), Runner introspection(list/peek), OTel GenAI **매핑 계층**(in-repo 순수 함수 — SDK 브리지는 OTel 전역 상태가 async 테스트 규율과 충돌해 `el_graph_otel` 패키지 몫으로 분리) | 충족: 도그푸딩 에이전트(`ElGraph.Demo` — 문서 Q&A, supervision 트리 + 실 OpenAI)가 실 API 통합 테스트로 동작 확인. 상시 구동: `mix run --no-halt scripts/demo.exs` |
| **M4 Skill/Sensor/Store** ✅ 완료 (2026-06-13) | `SignalReAct` Skill(도그푸딩 2표본에서 4-파라미터 추출), `Sensor`(폴링+tick), `Signal.Bus`(패턴 구독+fan-out, 발견 8 해소), `Store`+`Store.ETS`(장기 메모리, 공유 계약), `Nodes.Summarize`(컨텍스트 압축 — append `{:replace}` 마커 + Store 축출) | 충족: DocsAgent·SummarizeAgent를 `use SignalReAct` 한 블록으로 재구성, 센서→버스→에이전트 체인·요약+Store 모두 실 OpenAI 검증 |
| **M5 분산** 🔶 코어 완료 (2026-06-13) | 핸드오프(SignalReAct `:emit` → 버스 파이프라인), `:pg` 전송(Bus.Pg — Agent 구독 분산, 함수 구독 거부), A2A 매핑(`A2A` — Task 상태/Agent Card/Message 변환, 순수 함수) | 코어 충족: 2-에이전트 파이프라인·:pg fan-out 테스트 통과. 잔여: 멀티노드 통합(libcluster), A2A HTTP 서버(`el_graph_a2a` 패키지), 전달 보장/netsplit |
| **관측 트랙** 🔶 진행 중 (2026-06-14) | telemetry 계측(invoke/node/llm.chat span + retry/interrupt 이벤트) → OTel 브리지 → Langfuse 실전송 검증. ElTrace LiveView UI(별도 `el_trace` 앱, Phoenix/LiveView — #1 인터럽트 가시성·#2 thread 생애·#4 time-travel 분기) | Langfuse 연동은 실데이터 검증 완료. ElTrace `el_trace` 앱 분리 + LiveView 완료: Timeline 실시간 시각화(telemetry→PubSub), 인터럽트 승인/거절(resume), "여기서 분기"(Replay) — LiveViewTest + 브라우저 검증. 잔여: #3 핸드오프 그래프, `el_graph_otel` 앱 분리 |

## 9. 비목표

- 클린아키텍처식 계층(UseCase/Interactor) 도입 — behaviour 포트로 충분
- 자체 LLM 프롬프트 템플릿 언어 — 함수 합성으로 충분
- Python LangGraph와의 체크포인트 호환 — 비현실적, 추구하지 않음
- 노드별 프로세스 모델 — 노드는 함수다
- Evals/LLM-judge 프레임워크 — 테스트 키트(§7)가 mock 지점을 제공하는 선까지. 평가는 전용 도구의 영역
- 자유 대화(group chat) 런타임을 코어에 — graph-first 정체성과 충돌. L4 패턴 템플릿(§6)으로만 제공

## 10. 품질 게이트

- 모든 공개 API에 `@spec` + Dialyzer 통과. **Dialyzer 도입 완료(2026-06) — 움브렐라 5개 앱 전부**
  (`el_graph`·`el_graph_web`·`el_trace`·`el_graph_ecto`·`el_graph_redis`)에 dialyxir +
  `dialyzer:`(flags: error_handling/missing_return) 설정, 각 `mix dialyzer` **0 경고**. 도입 중 실타입
  버그 발견·수정: 노드/라우터/reducer 타입이 `mfa()`(=arity)로 잘못 선언돼 있던 것을
  `Graph.mfargs()`(`{module, fun, [args]}`)로 정정; `ElTrace.Telemetry.attach/0` 반환 계약을 `:ok`로
  명시. (`:extra_return`은 "넓지만 정확한" API 스펙—예: `iodata()`—에 false-positive라 제외.
  el_graph_ecto의 마이그레이션 mix 태스크는 Mix가 공유 PLT에 없어 나는 false-positive 3건을
  `.dialyzer_ignore.exs`로 격리.) PLT는 `_build`에 캐시.
- ExDoc 문서 + 모든 공개 함수에 doctest 또는 예제
- 테스트 전부 `async: true` (전역 상태 결합 금지의 리트머스)

## 11. 열린 질문

- hex 패키지명: `el_graph`, `elgraph` 모두 가용 확인(2026-06-11). 출시 전 재확인 후 점유
- 상태 스키마의 struct 기반 타이핑(현재는 맵+키 정의) 도입 여부 — 보류(맵+키 정의로 충분, struct는 필요해지면)
- 체크포인트 마이그레이션 헬퍼 API 형태 — v1 스키마가 실사용에서 굳은 뒤 설계
- ~~brainlid/langchain 재사용~~ → **결정(R6)**: 자체 Req 어댑터(`ElGraph.LLM.*`) 채택. 의존성 통제·중립 메시지 형식 일관성 우선
- **잔여(M5 후속)**: A2A HTTP 서버 패키지, OTel SDK 브리지 패키지, SSE 스트리밍, 멀티노드 통합 테스트(libcluster), 전달 보장/netsplit 대응 — 전부 별도 패키지·인프라 작업

## 12. 검토 이력

- **R1 (언어/시맨틱)**: throw가 병렬 Task 안에서 exit으로 변질되는 문제 → 노드 래퍼에서 catch 후 태그 반환(§3.6), 병렬 형제 노드의 인터럽트 시 쓰기 보존(§3.6), 다중 인터럽트의 카운터 매칭과 결정성 제약(§3.6), 라우터 순수성 요구(§3.3)
- **R2 (OTP/런타임)**: 병렬 fan-out 상태 복사 비용 → input projection 옵션(§3.4), async 체크포인트 쓰기의 순서 보장(§3.5), 러너 소유권/링크 기본값(§3.4)
- **R3 (생태계/제품)**: 패키지명 가용 확인(§11), 경쟁 구도 조사 및 차별점 명문화(§1), brainlid/langchain 재사용 검토 항목화(§11), 품질 게이트 신설(§10)
- **R4 (LangGraph 약점 대응, 2026-06-12)**: 알려진 약점 7개를 조사·분류하고 부록 A 대응표 신설. 신규 반영 — 실행 introspection(§3.4, M3), 체크포인트 보존 정책(§3.5, M2), 토큰/비용 예산 가드(§4, M2), 원칙 2개 추가(§1: 제어 흐름 위임, 오픈 코어)
- **R5 (2026 트렌드 반영, 2026-06-12)**: 에이전트 프레임워크 트렌드 조사(A2A 150+ 조직 채택, OTel GenAI 규약 플랫폼 채택, 멀티 에이전트 패턴 1급화, 컨텍스트 압축 표준화). 신규 반영 — A2A 어댑터+상태 매핑표(§6, M5), OTel GenAI 매핑 방침(§3.7, M3), 오케스트레이션 패턴 템플릿(§6, M5), 컨텍스트 압축 2층 설계(trim §3.1 M2 / 요약 §4 M4), Evals·자유 대화 런타임 비목표 명시(§9). 내구 실행·HITL·MCP 방향은 트렌드 일치 확인 — 변경 없음
- **R6 (구현 단계 종합, 2026-06-13)**: M1~M5 코어를 TDD로 구현하며 설계와 달라진 결정 확정 (아래 §13 구현 노트). 주요 변경 — Skill이 추상 컴포지션이 아니라 `SignalReAct`(시그널 구동 ReAct, 4-파라미터)로 도그푸딩에서 추출; LLM 어댑터는 in-repo(hex 분리 보류, SSE 미구현); SignalTransport는 Bus(`:local`/`:pg`)로 구체화; 핸드오프는 `:command, :handoff`가 아니라 Skill `:emit` + 버스로 단순화; A2A·OTel은 순수 매핑 계층만(HTTP/SDK 브리지는 별도 패키지). 도그푸딩 7세션의 마찰 13건 중 11건 해소(§DOGFOODING.md).

## 13. 구현 노트 (설계 → 실제)

SPEC 본문은 설계 시점 표기를 유지한다. 실제 구현이 본문과 다른 지점만 여기 정리한다 — 코드가 정본.

| SPEC 본문 | 실제 구현 | 사유 |
|---|---|---|
| §5 `use ElGraph.Agent, graph:, skills:` | `use ElGraph.Agent`(handle_signal/handle_result 콜백) + `use ElGraph.Skills.SignalReAct`(선언적) | Skill은 도그푸딩 후 추출 — 2표본의 공통 4-파라미터(route/tools/system/reply)로 수렴 |
| §4 LLM 어댑터 별도 패키지 `el_graph_llm` | in-repo (`ElGraph.LLM.OpenAI/Anthropic/Gemini`) | 출시 전 분리 재평가. SSE 스트리밍은 미구현(비스트리밍 우선) |
| §5 SignalTransport behaviour | `ElGraph.Signal.Bus`(`transport: :local`/`:pg`) | 버스가 곧 transport. `:pg`는 Agent 구독만 분산, 함수 구독 거부 |
| §6 핸드오프 `{:command, :handoff, ...}` | Skill `:emit` 옵션 → 버스 발행 | `:command` goto는 그래프 내 노드용. 핸드오프는 버스가 자연스러움 |
| §6 A2A 어댑터(Phoenix HTTP 서버) | `ElGraph.A2A` 순수 매핑(Task 상태/Agent Card/Message) | Task 상태가 M1 프리미티브와 1:1 → 순수 함수로 충분. HTTP 서버는 `el_graph_a2a` 몫 |
| §3.7 OTel 어댑터 | `ElGraph.OTel.Mapping` 순수 함수 | OTel SDK는 전역 상태라 async 테스트와 충돌 → 매핑만 in-repo, SDK 브리지는 `el_graph_otel` 몫 |
| §6 오케스트레이션 템플릿(supervisor/magentic) | 미구현 — 핸드오프/fan-out은 버스로 충분히 표현됨 | 템플릿은 표본이 더 쌓이면. 현재 버스+emit으로 파이프라인 동작 |
| §3.6 동적 인터럽트 throw | 노드 래퍼(Task 내부)에서 catch → 태그 반환 | R1 설계대로 구현. timeout 노드 안에서도 동작 검증 |
| §3.6 인터럽트 반환 `{:interrupted, ref, state}` | `{:interrupted, map()}` (ref 없는 2-튜플, `node`·`payload`·`next` 포함 맵) | resume이 ref 대신 thread_id로 매칭 → ref 불필요. §6 A2A 표·README도 2-튜플 기준 |

**추가 구현(설계에 없던 것)**: `Nodes.Summarize`의 append `{:replace}` 마커(LangGraph RemoveMessage 패턴), Agent `:thread` 정책(`:per_request`/`{:fixed,id}` — 도그푸딩 마찰 7), Skill reply의 usage 포함(마찰 3).

**관측 보강 (2026-06-14)**: LLM 어댑터 계측 — `ElGraph.LLM.Telemetry.instrument/3`가 세 어댑터(OpenAI/Anthropic/Gemini)의 `chat`을 `[:el_graph, :llm, :chat]` span으로 감싼다(provider·model·토큰·에러 메타). `OTel.Mapping`이 이를 GenAI `chat` generation(`gen_ai.system`/`gen_ai.request.model`/`gen_ai.usage.*`/`error.type`)으로 변환 — Langfuse 등 OTLP 백엔드가 generation으로 인식하는 핵심 데이터. **Langfuse 연동 방침**: 재구현하지 않고 OTLP로 연결. ElGraph는 telemetry/OTel span만 방출, 실제 OTLP export(trace context 전파 포함)는 `el_graph_otel` 브리지 패키지(미구현).

**실행 이벤트 계측 (2026-06-14)**: `:telemetry.execute`로 단발 이벤트 — `[:el_graph, :node, :retry]`(메타: node/step/thread_id/reason/attempt), `[:el_graph, :node, :interrupt]`(동적 인터럽트, 메타: node/step/thread_id/payload). span(invoke/node/llm.chat)과 함께 운영 관측의 토대. 잔여 계측: checkpoint 저장 이벤트, Agent/Bus/Sensor 레벨, 정적 인터럽트.

**OTel 브리지 + Langfuse (2026-06-14)**: `ElGraph.OTel.Bridge` — telemetry span을 OpenTelemetry span으로 변환(`opentelemetry_telemetry`로 부모-자식 컨텍스트 관리, 속성은 `OTel.Mapping`의 GenAI semconv). `langfuse_otlp_config/3`이 Langfuse OTLP/HTTP exporter 설정(Basic auth + `x-langfuse-ingestion-version`)을 생성. **방침 확정**: Langfuse를 재구현하지 않고 OTLP 표준으로 연동 — 같은 OTel span이 Langfuse/Datadog/Jaeger 등 어느 백엔드로든 흐른다. **OTel 의존성**(opentelemetry/exporter/telemetry)을 in-repo 추가(Windows 컴파일 확인), 향후 `el_graph_otel`로 분리 — 코어 "telemetry 1개" 원칙은 그때 복원. ~~한계: 병렬 노드(별도 Task)는 OTel 컨텍스트 자동 전파 안 됨(1차).~~ → **해소**: `Executor.exec_all`이 부모 OTel 컨텍스트를 캡처해 각 Task에서 `attach`하므로 병렬 노드 span이 invoke span 아래로 중첩된다(OTel 미사용 시 무비용). **실전송 검증 완료(2026-06-14)**: Langfuse self-host(docker-compose + headless init)로 `scripts/otel_langfuse.exs` 실행 → trace 1개 + observation 6개 도착. Langfuse가 `chat gpt-4o`를 GENERATION(model·토큰 정확), 노드를 TOOL, invoke를 SPAN으로 정확히 분류 — GenAI semconv 매핑이 실데이터로 검증됨. ReAct 루프(agent→tools→agent)가 중첩 trace로 표시.

**ElTrace 프로토타입 착수 (2026-06-14)**: Langfuse 관찰(도그푸딩 세션 8) 결과 "ElGraph가 체크포인트·버스로 아는 인과를 Langfuse는 모른다"는 4개 차별점을 데이터로 확정 — #1 인터럽트 가시성, #2 thread 생애(invoke→interrupt→resume), #3 멀티 에이전트 핸드오프, #4 time-travel 재개. 우선순위 #1·#2를 구현: `ElTrace.Timeline`(체크포인트 체인 → 생애 타임라인 + 텍스트 렌더). 선결로 `Checkpoint.interrupt_info`(node+payload)를 추가 — 동적 인터럽트가 기록하고 재개 후에도 보존(Langfuse가 못 보여준 "왜 멈췄나"의 데이터 소스). 시연: `scripts/eltrace_demo.exs`. **방침**: ElTrace는 범용 trace(span/토큰)를 재구현하지 않고 Langfuse에 위임 — 체크포인트가 아는 인과만 다룬다. **구조**: `lib/el_trace/`에 두되 ElGraph 의존은 Checkpointer behaviour뿐 — 별도 앱(`el_trace`) 분리에 유리.

**#4 time-travel 재개 추가**: `ElTrace.Replay.from/5` + `Executor.resume_from/3` — 임의 과거 step의 체크포인트 상태로 새 thread를 분기(fork)해 재실행, 원래 thread 보존. "if 시나리오"(승인↔거절) 탐색이 안전하게 가능 — Langfuse가 trace를 보여주기만 하는 것과 대비되는 ElGraph만의 기능. 시연으로 검증(승인 완료 thread 보존 + step 1로 되감아 거절 분기). **#1·#2·#4의 데이터/제어 계층이 전부 Phoenix 없이 동작** — LiveView는 이 위의 순수 표현 작업(Timeline 시각화 + 인터럽트 승인/Replay 버튼). 잔여: LiveView 실시간 UI(Phoenix 의존, `el_trace` 앱 분리 권장), #3 핸드오프 그래프(버스 시그널 인과). **자체 관측 도구(ElTrace) 방침**: 풀 Langfuse 클론은 비목표. ElGraph 차별점(체크포인트 time-travel·LiveView 실시간·BEAM 내장)만 OTel 위에 쌓는다 — Langfuse로 한동안 도그푸딩 후 추출.

## 14. 보고서 반영 확장 (2026-06, Agentic AI 트렌드)

`docs/agentic-ai-2026-report.html`의 2026 트렌드 분석을 근거로 추가·심화한 기능. 각 항목은
계획→TDD→테스트로 구현했고 항목별 완성도 9.5/10을 목표로 함(추적: `docs/report-checklist.md`).
모든 모듈은 기존 프리미티브 위의 격리된 추가이며 코어 실행기 의존을 늘리지 않는다.

| # | 기능 | 모듈 / 앱 | 요지 | 테스트 |
|---|---|---|---|---|
| T1.1 | **AG-UI 매핑** | `ElGraph.AGUI` | ElGraph 스트림 → AG-UI 이벤트 시퀀스(RUN/STEP/TEXT_MESSAGE/TOOL_CALL/STATE_SNAPSHOT/STATE_DELTA/MESSAGES_SNAPSHOT/CUSTOM). 노드 단위 메시지 프레이밍, `transform/3`(상태추적)·`encode/1`(무상태) | 22 |
| T1.2 | **LLM SSE 스트리밍** | `ElGraph.LLM` + `LLM.SSE` + OpenAI/Anthropic/Gemini | 선택 콜백 `stream_chat/3`, 순수 SSE 프레이밍, 증분 토큰 + (OpenAI) 증분 도구호출 델타, 노드 헬퍼 `LLM.stream_to_ctx/4`, 에러 매핑 | 31+ |
| T1.3 | **A2A + AG-UI HTTP 서버** | `el_graph_web`(신규 앱) | Plug/Bandit. A2A JSON-RPC 2.0(`message/send`·`tasks/get`·`message/stream` SSE), `.well-known/agent-card.json`, `TaskStore`, AG-UI `/agui/:name/run` SSE. `server_spec/1`로 호스트 마운트(전역 서버 자동기동 안 함) | 28 |
| T1.4 | **OTel 병렬 컨텍스트 전파** | `ElGraph.Executor.exec_all`, `OTel.Mapping` | 병렬 Task에 부모 OTel 컨텍스트 캡처+attach → 노드 span이 invoke span 아래 중첩. Mapping에 invoke/node `error.type` 추가 | 8 + 연계 |
| T2.5 | **오케스트레이션 템플릿** | `ElGraph.Orchestration` | `supervisor/3`(오케스트레이터-워커), `group_chat/2`(스피커 선택 정책), `magentic/3`(task-ledger + 무한루프 stall guard) | 11 + int |
| T2.6 | **고급 메모리** | `ElGraph.Memory` (+`Memory.Embedder`) | 3-스코프(episodic/semantic/procedural) + 시점진실(latest-wins), 시맨틱 recall(`recall_relevant/4`, cosine), supersede 이력(`fact_history/3`), `forget/4`. Store behaviour만 사용 | 16 |
| T3.8 | **Evals** | `ElGraph.Eval` | 데이터셋 평가 + 플러그형 스코어러 + LLM-judge, **체크포인트-리플레이 평가**(`replay_eval/6`, time-travel), 병렬 평가 + 집계 메트릭, JSONL 로딩, baseline 회귀 비교(`compare/2`) | 13 |
| T3.9 | **가드레일 / 정책** | `ElGraph.Guardrail` (+`Guardrail.PII`) | deny/redact/max_length/authorize_tool + PII 라이브러리(email/phone/card/ssn/rrn/ipv4), 구조화 출력 검증(`validate_schema/1`, NimbleOptions), 차단 telemetry, 노드 통합 `guard_value/4` | 25 |
| T3.10 | **샌드박스 코드 실행** | `ElGraph.Sandbox`(+`.Command`/`.Docker`) + `Actions.CodeExec` | 외부 격리 위임 behaviour. 타임아웃(`run_with_timeout`, 누수 없음)·출력 크기 제한, Docker 백엔드(`--network=none`/`--read-only`/mem·cpu 기본값). **인프로세스 eval 안 함** | 16 + int |

> T2.7(내구 실행 · Postgres/Redis/DETS/Mnesia 체크포인터)은 §3.5에 반영됨(별도 작업으로 완료).

**관측 연계 검증**: ① **Langfuse 파이프라인** — `test/el_graph/otel/langfuse_pipeline_test.exs`(`:integration`)가 OTel SDK + pid exporter로 telemetry→Bridge→OTel span을 포착해 `invoke_workflow` 아래 병렬 노드 span 중첩을 단언(Langfuse가 OTLP로 받는 바로 그 데이터). ② **ElTrace** — `apps/el_trace/test/el_trace/new_features_integration_test.exs`가 멀티 에이전트 오케스트레이션 실행의 체크포인트 체인을 ElTrace 생애 타임라인으로 관측·분기(time-travel)함을 단언.

**현황 요약(2026-06)**: el_graph 403 + el_graph_web 28 + el_trace 29 = 460 테스트(전부 async) + 통합 다수. 품질 루브릭은 `docs/quality-rubric.md`.

## 부록 A — LangGraph 약점 대응표

LangGraph의 알려진 약점(2026-06 조사)과 ElGraph의 설계 대응. ✅ = BEAM/설계로 구조적 해결, ◐ = 부분 완화.

| # | LangGraph 약점 | ElGraph 대응 | 근거 |
|---|---|---|---|
| 1 | **디버깅·관측 불투명** — 추상화된 상태 관리로 멀티 에이전트 디버깅이 어렵고, 실질적 관측은 유료 LangSmith에 의존 | ✅ telemetry 이벤트 M1 내장 + Runner introspection(`list`/`peek`, §3.4) + `:observer`/`:sys`/원격 IEx로 실행 중 프로세스 직접 조회 | §3.7, §3.4 |
| 2 | **스케일 저하** — 그래프·동시 실행이 커지면 느려지고 메모리 증가 (GIL, asyncio 단일 루프, sync/async 이중 API) | ✅ 호출당 BEAM 프로세스 + 선점 스케줄링 + 모든 코어 활용. API 단일화(색깔 있는 함수 없음). input projection으로 복사 비용 제어 | §3.4, 비교문서 §1 |
| 3 | **과도한 추상화·학습 곡선** — 언어가 이미 제공하는 제어 흐름을 프레임워크로 재구현 | ◐ 그래프는 영속성·관측·병렬·재개가 필요한 지점에만. 노드는 그냥 함수, 단순 분기는 패턴 매칭으로 — 프레임워크 밖으로 나가는 길을 항상 열어둔다 | §1 원칙 |
| 4 | **루프 토큰 폭주** — unmanaged loop가 비용 사고로 직결 | ✅ `max_steps` 기본값(M1 구현됨) + 토큰/비용 예산 초과 시 동적 인터럽트로 사람에게 에스컬레이션(M2) | §3.4, §4 |
| 5 | **생태계 락인** — LangChain 결합 + 백그라운드 실행·HITL 운영은 유료 Platform에 묶임 | ✅ 의존성 1개 코어, LLM은 behaviour 뒤에. 내구 백그라운드 실행·HITL·체크포인트가 전부 오픈 코어(L1/L3)에 있다 — 상위 유료 계층 없음 | §1, §3.5~3.6, §5 |
| 6 | **체크포인트 저장 비대화** — 매 스텝 전체 상태 스냅샷이 긴 thread에서 저장소를 압박 (자체 분석) | ◐ 빈도 정책(`checkpoint:`) + 보존 정책(`keep: {:last, n}`, M2). 델타 인코딩은 열린 질문 | §3.5 |
| 7 | **약타입 상태** — dict 기반이라 오타·미선언 키가 런타임 깊숙이서 터짐 | ✅ 상태 키 compile 선언 강제 + 미선언 키 쓰기 즉시 에러 + 병렬 쓰기 충돌 검출(M1 구현됨). struct 타이핑은 M2 재평가 | §3.1, §3.4 |
