# Durability 모드별 invoke 지연 — 체크포인트 영속 시점에 따른 비용 차이.
# 기준선(체크포인터 없음) 대비 :sync(매 step 동기) / :async(쓰기 프로세스) / :exit(종료 시 1회).
#
#   cd apps/el_graph && mix run bench/durability_modes.exs
#   BENCH_TIME=1 mix run bench/durability_modes.exs   # 빠른 스모크
#
# 체크포인터는 ETS(BEAM 내장, 외부 인프라 0). 8-superstep 체인이라 :sync는 8회,
# :exit는 1회 영속한다 — 모드 간 차이가 드러난다.

time = String.to_integer(System.get_env("BENCH_TIME", "3"))

{:ok, cp_pid} = ElGraph.Checkpointer.ETS.start_link()
cp = {ElGraph.Checkpointer.ETS, ElGraph.Checkpointer.ETS.config(cp_pid)}

inc = fn %{n: n}, _ctx -> %{n: n + 1} end

graph =
  Enum.reduce(1..8, ElGraph.new() |> ElGraph.state(:n, default: 0), fn i, g ->
    ElGraph.add_node(g, :"s#{i}", inc)
  end)
  |> then(fn g ->
    Enum.reduce(1..7, g, fn i, g -> ElGraph.add_edge(g, :"s#{i}", :"s#{i + 1}") end)
  end)
  |> ElGraph.compile(entry: :s1)

durable = fn mode ->
  tid = "bench-#{System.unique_integer([:positive])}"
  {:ok, _} = ElGraph.invoke(graph, %{n: 0}, checkpointer: cp, thread_id: tid, durability: mode)
end

Benchee.run(
  %{
    "no checkpointer (baseline)" => fn -> {:ok, _} = ElGraph.invoke(graph, %{n: 0}) end,
    ":sync (per-step persist)" => fn -> durable.(:sync) end,
    ":async (writer process)" => fn -> durable.(:async) end,
    ":exit (final only)" => fn -> durable.(:exit) end
  },
  time: time,
  warmup: 1,
  memory_time: 1
)
