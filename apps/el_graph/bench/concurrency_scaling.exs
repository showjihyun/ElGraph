# 동시 에이전트 스케일링 — BEAM 경량 프로세스로 N개 에이전트(invoke)를 동시에 돌린다.
# 100 → 1k → 10k로 키우며 전체 처리 시간을 측정한다(스케줄러가 모든 코어를 자동 활용).
#
#   cd apps/el_graph && mix run bench/concurrency_scaling.exs
#   BENCH_TIME=1 mix run bench/concurrency_scaling.exs   # 빠른 스모크
#
# 각 에이전트는 2-superstep 그래프(double → inc)를 한 번 실행한다 — 오케스트레이터 런타임
# 오버헤드만 측정하도록 노드는 순수 CPU 경량 연산이다(LLM/IO 없음).

time = String.to_integer(System.get_env("BENCH_TIME", "3"))

graph =
  ElGraph.new()
  |> ElGraph.state(:n, default: 0)
  |> ElGraph.add_node(:double, fn %{n: n}, _ctx -> %{n: n * 2} end)
  |> ElGraph.add_node(:inc, fn %{n: n}, _ctx -> %{n: n + 1} end)
  |> ElGraph.add_edge(:double, :inc)
  |> ElGraph.compile(entry: :double)

run_agents = fn n ->
  1..n
  |> Task.async_stream(fn i -> {:ok, _} = ElGraph.invoke(graph, %{n: i}) end,
    max_concurrency: n,
    ordered: false,
    timeout: :infinity
  )
  |> Stream.run()
end

Benchee.run(
  %{"concurrent ElGraph.invoke" => run_agents},
  inputs: %{"100 agents" => 100, "1k agents" => 1_000, "10k agents" => 10_000},
  time: time,
  warmup: 1,
  memory_time: 1,
  print: [fast_warning: false]
)
