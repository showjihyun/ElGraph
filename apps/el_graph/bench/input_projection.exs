# Input projection 효과 — 큰 state에서 노드가 필요한 키만 받도록 하면(`input: [...]`)
# 병렬 노드로 복사되는 state 양이 줄어 시간/메모리가 절감되는지 측정한다(before/after).
#
#   cd apps/el_graph && mix run bench/input_projection.exs
#   BENCH_TIME=1 mix run bench/input_projection.exs   # 빠른 스모크
#
# state에 2KB 블롭 50개(~100KB)를 싣고, 8-갈래 병렬 워커가 :n 한 개만 필요로 한다.
# projection 없으면 워커마다 full state가, 있으면 %{n: _}만 전달된다.

alias ElGraph.Reducers

time = String.to_integer(System.get_env("BENCH_TIME", "3"))

blob = :binary.copy(<<0>>, 2048)
blob_keys = for i <- 1..50, do: :"blob#{i}"
init = blob_keys |> Map.new(fn k -> {k, blob} end) |> Map.put(:n, 0)

build = fn projected? ->
  base =
    Enum.reduce(
      blob_keys,
      ElGraph.new()
      |> ElGraph.state(:n, default: 0)
      |> ElGraph.state(:hits, default: [], reducer: {Reducers, :append, []}),
      fn k, g -> ElGraph.state(g, k) end
    )

  worker_opts = if projected?, do: [input: [:n]], else: []

  graph =
    Enum.reduce(1..8, base, fn i, g ->
      ElGraph.add_node(g, :"w#{i}", fn _s, _ctx -> %{hits: [1]} end, worker_opts)
    end)
    |> ElGraph.add_node(:start, fn _s, _ctx -> %{} end)

  Enum.reduce(1..8, graph, fn i, g -> ElGraph.add_edge(g, :start, :"w#{i}") end)
  |> ElGraph.compile(entry: :start)
end

with_projection = build.(true)
without_projection = build.(false)

Benchee.run(
  %{
    "no projection (full state per worker)" => fn ->
      {:ok, _} = ElGraph.invoke(without_projection, init)
    end,
    "input: [:n] projection" => fn -> {:ok, _} = ElGraph.invoke(with_projection, init) end
  },
  time: time,
  warmup: 1,
  memory_time: 2
)
