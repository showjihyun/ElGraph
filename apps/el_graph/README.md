# ElGraph

**BEAM(Elixir/OTP) 위에서 도는 graph-first 에이전트 프레임워크.** 내구 실행·HITL(사람 개입)·
time-travel·체크포인트 — LangGraph가 Python에서 라이브러리로 재구현한 것이, 여기선 런타임 기본이다.
Python 없음.

`el_graph`는 **코어 런타임**이다: 그래프 실행기, 체크포인터, 에이전트 런타임, LLM/MCP 어댑터.
런타임 의존성은 `:telemetry` 하나.

> [ElGraph 우산 프로젝트](https://github.com/showjihyun/ElGraph)의 일부. 실시간 관측 UI(ElTrace),
> A2A/AG-UI HTTP 서버, Postgres/Redis 체크포인터, OpenTelemetry 브리지는 형제 패키지에 있다.
>
> 전체 문서: [English](https://github.com/showjihyun/ElGraph/blob/main/README.md) ·
> [한국어](https://github.com/showjihyun/ElGraph/blob/main/README.ko.md)

## 설치

아직 Hex 미출시 — git 의존성으로 가져온다(공개 저장소라 **설치 인증 불필요**):

```elixir
def deps do
  [
    # 우산 서브앱이라 sparse로 코어만 가져온다:
    {:el_graph, github: "showjihyun/ElGraph", sparse: "apps/el_graph"}
    # (향후 Hex 출시 시) {:el_graph, "~> 0.3"}
  ]
end
```

ElGraph는 전역 프로세스를 스스로 시작하지 않는다 — 필요한 것(Task.Supervisor, 체크포인터 테이블
소유 프로세스 등)을 호스트 앱의 슈퍼비전 트리에 마운트한다.

## 첫 그래프 (30초)

```elixir
graph =
  ElGraph.new()
  |> ElGraph.state(:n, default: 0)
  |> ElGraph.add_node(:double, fn %{n: n}, _ctx -> %{n: n * 2} end)
  |> ElGraph.add_node(:inc, fn %{n: n}, _ctx -> %{n: n + 1} end)
  |> ElGraph.add_edge(:double, :inc)
  |> ElGraph.compile(entry: :double)

ElGraph.invoke(graph, %{n: 10})
#=> {:ok, %{n: 21}}
```

노드는 `(state, ctx)`를 받아 상태 부분 업데이트 맵을 돌려준다. 그게 전부다.

## 첫 에이전트 — API 키 불필요

`ElGraph.Test.ScriptedLLM`은 미리 정한 응답을 돌려주므로, 자격증명 없이 ReAct 에이전트 루프를
그대로 돌려볼 수 있다:

```elixir
alias ElGraph.{LLM, Presets}
alias ElGraph.Test.ScriptedLLM

{:ok, pid} = ScriptedLLM.start_link([LLM.assistant("안녕하세요! 무엇을 도와드릴까요?")])
graph = Presets.react({ScriptedLLM, pid}, [])

ElGraph.invoke(graph, %{messages: [LLM.user("안녕")]})
#=> {:ok, %{messages: [%{role: :user, ...}, %{role: :assistant, content: "안녕하세요! ..."}], ...}}
```

준비되면 실제 어댑터로 교체 — `ElGraph.LLM.OpenAI` / `.Anthropic` / `.Gemini`.

## 내구 실행 + 사람 개입(HITL)

```elixir
# BEAM 내장 체크포인터 — 외부 인프라 0
cp = {ElGraph.Checkpointer.ETS, ElGraph.Checkpointer.ETS.config(owner_pid)}

# 승인이 필요한 지점에서 멈춘다...
{:interrupted, %{node: :approve, payload: _}} =
  ElGraph.invoke(graph, input, checkpointer: cp, thread_id: "t1")

# ...사람의 답을 주입해 재개 — 완료된 노드는 재실행하지 않는다
{:ok, final} = ElGraph.resume(graph, checkpointer: cp, thread_id: "t1", resume: "approved")
```

코어에 내장된 체크포인터: `ETS`(인메모리), `DETS` / `Mnesia`(BEAM 내장 디스크 영속, 인프라 0).
Postgres·Valkey/Redis 백엔드는 형제 패키지(`el_graph_ecto`, `el_graph_redis`).

## 라이선스

[MIT](LICENSE) © 2026 Poor Coin Pepe
