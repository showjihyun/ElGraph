# observed_agent — el_graph + el_trace를 의존성으로 쓰는 예제

우산(`apps/`) **밖**의 독립 프로젝트가 분리된 두 앱을 다시 의존성으로 묶어 쓰는 예제다.

- `el_graph` — 그래프 실행 코어
- `el_trace` — 관측 LiveView (의존성으로 끌어오면 자체 Phoenix 엔드포인트가 함께 뜬다)

## 의존성 (`mix.exs`)

```elixir
defp deps do
  [
    {:el_graph, path: "../../apps/el_graph"},   # git/hex 의존성도 동일
    {:el_trace, path: "../../apps/el_trace"}
  ]
end
```

`el_trace`는 `mod: {ElTrace.Application, ...}`이라 호스트 앱이 부팅되면 의존성으로서
**자동으로 시작**된다 — PubSub·Sessions·엔드포인트가 함께 뜬다. 호스트는 끌어온 엔드포인트를
`config/config.exs`에서 설정하기만 하면 된다(`server: true`, `secret_key_base`,
`pubsub_server: ElTrace.PubSub`, `adapter: Bandit.PhoenixAdapter` 등).

## 사용 (`lib/observed_agent.ex`)

그래프를 실행해 인터럽트까지 보낸 뒤 한 줄로 등록한다:

```elixir
cp = {ElGraph.Checkpointer.ETS, ETS.config(ObservedAgent.Checkpointer)}
{:interrupted, _} = ElGraph.invoke(graph, %{}, checkpointer: cp, thread_id: "consumer-결제-승인")
ElTrace.observe("consumer-결제-승인", graph, cp)
```

`ElTrace.observe/4`는 그래프+체크포인터를 ElTrace에 등록한다 — UI가 resume/분기에 필요한
컴파일된 그래프를 갖게 된다(체크포인트에는 그래프 정의가 없으므로).

### "여기서 분기"로 거절 분기 만들기 (time-travel)

UI의 **여기서 분기** 버튼과 같은 동작을 코드로도 할 수 있다. 인터럽트 지점에서 분기해
**"거절"로 진행**하면, 원본(승인 대기)은 그대로 보존된 채 "거절했다면?" 시나리오가 새 thread로 생긴다:

```elixir
# 인터럽트(step)에서 분기 → 분기 thread는 같은 지점에서 다시 멈춘다
{:ok, fork_id, {:interrupted, _}} = ElTrace.fork("consumer-결제-승인", step, as: "consumer-결제-승인-거절")
# 분기 thread만 "거절"로 재개 — 원본은 불변
ElGraph.resume(graph, checkpointer: cp, thread_id: fork_id, resume: "거절")
```

`ElTrace.fork/3`는 `ElTrace.Replay`(time-travel fork) + `observe`(부모 계보 등록)를 한 번에 한다.

## 실행

```bash
# (최초 1회) el_trace 자산 빌드 — 브라우저 LiveView JS
cd ../../apps/el_trace && mix esbuild el_trace && cd -

cd examples/observed_agent
mix deps.get
mix run --no-halt        # el_trace 엔드포인트가 :4000 에서 뜬다
```

브라우저(http://localhost:4000)에 두 thread가 보인다:

- **`consumer-결제-승인`** — 승인 대기(인터럽트). 직접 승인/거절, 또는 step에서 여기서 분기.
- **`consumer-결제-승인-거절`** (`⑂ from consumer-결제-승인`) — 코드로 만든 거절 분기. 같은
  지점에서 갈라져 "거절"로 완료됐고, 원본은 그대로 보존된다.

`--no-halt`는 VM을 살려 둬 엔드포인트가 계속 서빙하게 한다.
