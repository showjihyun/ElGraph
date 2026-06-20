# Superstep 처리량 — 단일 invoke가 그래프 모양에 따라 얼마나 빨리 도는지.
# 순차 체인 vs 병렬 팬아웃(BSP superstep당 병렬 노드 실행)을 비교한다.
#
#   cd apps/el_graph && mix run bench/superstep_throughput.exs
#   BENCH_TIME=1 mix run bench/superstep_throughput.exs   # 빠른 스모크

alias ElGraph.Reducers

time = String.to_integer(System.get_env("BENCH_TIME", "3"))

inc = fn %{n: n}, _ctx -> %{n: n + 1} end

# 8-노드 순차 체인 — superstep이 8번 직렬로 진행된다.
sequential =
  Enum.reduce(1..8, ElGraph.new() |> ElGraph.state(:n, default: 0), fn i, g ->
    ElGraph.add_node(g, :"s#{i}", inc)
  end)
  |> then(fn g ->
    Enum.reduce(1..7, g, fn i, g -> ElGraph.add_edge(g, :"s#{i}", :"s#{i + 1}") end)
  end)
  |> ElGraph.compile(entry: :s1)

# 8-갈래 병렬 팬아웃 — 한 superstep에서 8개 노드가 동시에 실행되어 :hits에 누적된다.
add_hit = fn _state, _ctx -> %{hits: [1]} end

fan_out =
  Enum.reduce(1..8, ElGraph.new() |> ElGraph.state(:hits, default: [], reducer: {Reducers, :append, []}), fn i, g ->
    ElGraph.add_node(g, :"w#{i}", add_hit)
  end)
  |> ElGraph.add_node(:start, fn _s, _ctx -> %{} end)
  |> then(fn g ->
    Enum.reduce(1..8, g, fn i, g -> ElGraph.add_edge(g, :start, :"w#{i}") end)
  end)
  |> ElGraph.compile(entry: :start)

Benchee.run(
  %{
    "sequential 8-node chain" => fn -> {:ok, _} = ElGraph.invoke(sequential, %{n: 0}) end,
    "parallel 8-branch fan-out" => fn -> {:ok, _} = ElGraph.invoke(fan_out, %{}) end
  },
  time: time,
  warmup: 1,
  memory_time: 1
)
