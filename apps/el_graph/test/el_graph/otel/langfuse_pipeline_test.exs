defmodule ElGraph.OTel.LangfusePipelineTest do
  # Langfuse 연계 검증: telemetry → Bridge → OpenTelemetry span (OTLP로 Langfuse에 가는 바로 그 데이터).
  # 라이브 Langfuse 없이 OTel SDK + pid exporter로 실제 방출되는 span을 포착해 검증한다.
  # SDK는 전역 상태라 async: false + :integration 태그(기본 제외, `--only integration`으로 실행).
  use ExUnit.Case, async: false

  @moduletag :integration

  require Record
  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  alias ElGraph.OTel.Bridge

  defmodule Nodes do
    def start(_state, _ctx), do: %{}
    def a(_state, _ctx), do: %{a: 1}
    def b(_state, _ctx), do: %{b: 2}
  end

  setup do
    Application.stop(:opentelemetry)
    Application.put_env(:opentelemetry, :span_processor, :simple)
    Application.put_env(:opentelemetry, :traces_exporter, :none)
    {:ok, _} = Application.ensure_all_started(:opentelemetry)
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    :ok = Bridge.attach()

    on_exit(fn ->
      Bridge.detach()
      Application.stop(:opentelemetry)
    end)

    :ok
  end

  test "a graph run emits an invoke_workflow span with nested parallel node spans" do
    graph =
      ElGraph.new()
      |> ElGraph.state(:a)
      |> ElGraph.state(:b)
      |> ElGraph.add_node(:start, &Nodes.start/2)
      |> ElGraph.add_node(:a, &Nodes.a/2)
      |> ElGraph.add_node(:b, &Nodes.b/2)
      |> ElGraph.add_edge(:start, :a)
      |> ElGraph.add_edge(:start, :b)
      |> ElGraph.compile(entry: :start)

    {:ok, %{a: 1, b: 2}} = ElGraph.invoke(graph, %{}, thread_id: "lf-pipe")

    spans = collect_spans()
    names = Enum.map(spans, &span(&1, :name))

    invoke = Enum.find(spans, &(span(&1, :name) == "invoke_workflow"))
    assert invoke, "expected an invoke_workflow span, got: #{inspect(names)}"

    node_spans = Enum.filter(spans, &String.starts_with?(span(&1, :name), "execute_tool"))
    assert length(node_spans) >= 3, "expected node spans for start/a/b, got: #{inspect(names)}"

    # 핵심: 병렬 노드(별도 Task) span이 invoke span 아래로 중첩된다 (T1.4 컨텍스트 전파 종단 검증,
    # = Langfuse가 trace를 올바른 부모-자식으로 그리는 근거).
    invoke_id = span(invoke, :span_id)
    parallel = Enum.filter(node_spans, &(span(&1, :name) in ["execute_tool a", "execute_tool b"]))
    assert parallel != []

    assert Enum.all?(parallel, &(span(&1, :parent_span_id) == invoke_id)),
           "parallel node spans must nest under invoke (OTel context propagation)"
  end

  defp collect_spans(acc \\ []) do
    receive do
      {:span, s} -> collect_spans([s | acc])
    after
      500 -> Enum.reverse(acc)
    end
  end
end
