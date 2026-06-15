# ElGraphWeb

ElGraph 그래프/에이전트를 **표준 에이전트 프로토콜**로 노출하는 HTTP 서버.
순수 매핑(`ElGraph.A2A` / `ElGraph.AGUI`) 위의 얇은 Plug/Bandit 계층이다.

- **A2A (Agent2Agent)** — JSON-RPC 2.0로 조직 경계 밖 에이전트와 상호운용
- **AG-UI (Agent-User Interaction)** — SSE로 프론트엔드에 실시간 스트리밍

ElGraph 원칙대로 전역 서버를 자동 시작하지 않는다 — 호스트 앱이 `server_spec/1`을
자신의 슈퍼비전 트리에 마운트한다.

## 마운트

```elixir
agents = %{
  "docs" => %{graph: MyApp.docs_graph(), card: [name: "docs", description: "문서 Q&A", tools: []]}
}

children = [
  {ElGraphWeb.TaskStore, name: MyApp.TaskStore},
  ElGraphWeb.server_spec(
    agents: agents,
    task_store: MyApp.TaskStore,
    port: 4001,
    api_keys: ["sk-..."],                                     # 비우면 인증 비활성(개방)
    guardrails: [ElGraph.Guardrail.deny_pii([:credit_card])]  # 입력 스크리닝(선택)
  )
]
```

`server_spec/1` 옵션:

| 옵션 | 설명 |
|---|---|
| `:agents` (필수) | `%{name => %{graph:, card:}}` 레지스트리 |
| `:task_store` | A2A Task 저장소 ref (`message/send`/`tasks/get`용). 미지정 시 task 영속 안 함 |
| `:port` | 기본 4001 |
| `:api_keys` | 허용 키 목록. **비었으면 인증 비활성**, 있으면 `Authorization: Bearer <key>` 또는 `x-api-key` 요구(없으면 401) |
| `:guardrails` | 입력 가드 목록(`ElGraph.Guardrail`). 차단 시 graph 미실행(JSON-RPC `-32602` / HTTP 403) |

## 엔드포인트

| 메서드 · 경로 | 설명 |
|---|---|
| `GET  /a2a/:name/.well-known/agent-card.json` | A2A Agent Card |
| `GET  /a2a/:name/agent-card` | 동일(레거시 경로) |
| `POST /a2a/:name` | **A2A JSON-RPC 2.0** — `message/send`, `tasks/get`, `message/stream`(SSE) |
| `POST /a2a/:name/message` | A2A 메시지 → Task 상태(REST) |
| `POST /agui/:name/run` | **AG-UI 이벤트 SSE 스트림**(`text/event-stream`) |

### A2A JSON-RPC 예시

```bash
# message/send → 완료된 Task 반환
curl -X POST http://localhost:4001/a2a/docs \
  -H 'content-type: application/json' \
  -H 'authorization: Bearer sk-...' \
  -d '{"jsonrpc":"2.0","id":1,"method":"message/send",
       "params":{"message":{"role":"user","parts":[{"text":"ElGraph가 뭐야?"}]}}}'

# tasks/get → 저장된 Task 조회
curl -X POST http://localhost:4001/a2a/docs \
  -d '{"jsonrpc":"2.0","id":2,"method":"tasks/get","params":{"id":"<task_id>"}}'
```

에러 코드: `-32600`(Invalid Request) · `-32601`(Method not found) · `-32001`(Task not found) ·
`-32602`(가드레일 차단).

### AG-UI 스트림 예시

```bash
curl -N -X POST http://localhost:4001/agui/docs/run \
  -H 'content-type: application/json' \
  -d '{"question":"엘릭서 검색해줘"}'
# → data: {"type":"RUN_STARTED",...}  data: {"type":"TEXT_MESSAGE_CONTENT",...} ...
```

AG-UI 이벤트: `RUN_STARTED`/`RUN_FINISHED`/`RUN_ERROR`, `STEP_STARTED`/`STEP_FINISHED`,
`TEXT_MESSAGE_START`/`_CONTENT`/`_END`, `TOOL_CALL_START`/`_ARGS`/`_END`, `STATE_SNAPSHOT` 등
(`ElGraph.AGUI`).

## 보안

- **인증**: `:api_keys`가 있으면 Bearer/x-api-key 검사(없거나 틀리면 401). 비었으면 개방.
- **가드레일**: `:guardrails`로 들어오는 메시지 텍스트를 LLM 호출 전에 스크리닝 — 차단 시 그래프를
  실행하지 않는다. PII 마스킹/차단·구조화 검증 등은 `ElGraph.Guardrail` 참고.

## 테스트

```bash
cd apps/el_graph_web
mix test            # Plug.Test 단위 + 라이브 Bandit 통합(localhost)
```
