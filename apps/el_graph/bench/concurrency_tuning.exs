# Experiment: how does `max_concurrency` affect the time to run a fixed batch of agents?
# `concurrency_scaling.exs` runs all N agents at once (max_concurrency: N). On a machine with
# C cores, launching 10k simultaneous tasks can oversubscribe the schedulers. This sweeps the
# cap to find the throughput-optimal concurrency for the same 10k-agent batch.
#
#   cd apps/el_graph && mix run bench/concurrency_tuning.exs
#   BENCH_TIME=1 mix run bench/concurrency_tuning.exs   # quick smoke

time = String.to_integer(System.get_env("BENCH_TIME", "3"))
n = String.to_integer(System.get_env("AGENTS", "10000"))
cores = System.schedulers_online()

graph =
  ElGraph.new()
  |> ElGraph.state(:n, default: 0)
  |> ElGraph.add_node(:double, fn %{n: n}, _ctx -> %{n: n * 2} end)
  |> ElGraph.add_node(:inc, fn %{n: n}, _ctx -> %{n: n + 1} end)
  |> ElGraph.add_edge(:double, :inc)
  |> ElGraph.compile(entry: :double)

run = fn mc ->
  1..n
  |> Task.async_stream(fn i -> {:ok, _} = ElGraph.invoke(graph, %{n: i}) end,
    max_concurrency: mc,
    ordered: false,
    timeout: :infinity
  )
  |> Stream.run()
end

IO.puts("\nBatch = #{n} agents on #{cores} cores. Sweeping max_concurrency.\n")

Benchee.run(
  %{
    "unbounded (#{n})" => fn -> run.(n) end,
    "cores*100 (#{cores * 100})" => fn -> run.(cores * 100) end,
    "cores*50 (#{cores * 50})" => fn -> run.(cores * 50) end,
    "cores*16 (#{cores * 16})" => fn -> run.(cores * 16) end,
    "cores*4 (#{cores * 4})" => fn -> run.(cores * 4) end,
    "cores (#{cores})" => fn -> run.(cores) end
  },
  time: time,
  warmup: 1
)
