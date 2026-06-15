defmodule ElGraph.OTel.LangfuseExportTest do
  # 종단 검증: telemetry → Bridge → OTel span → **실제 opentelemetry_exporter의 OTLP/HTTP POST**.
  # langfuse_pipeline_test 는 pid exporter로 span 내용을 검증한다. 이 테스트는 그 다음 hop —
  # 실제 exporter가 Langfuse auth 헤더 + protobuf 본문으로 OTLP/HTTP POST 하는 "바로 그 HTTP 요청"을
  # 로컬 Plug 스텁으로 포착해 검증한다(라이브 Langfuse 없이).
  # SDK + exporter app env 는 전역 상태라 async: false + :integration 태그(기본 제외).
  use ExUnit.Case, async: false

  @moduletag :integration

  alias ElGraph.OTel.Bridge

  # 고정 고포트. el_graph_web/test/.../integration_test.exs 와 동일한 패턴(Bandit `port: 0`의
  # 바인딩 포트를 Bandit→ThousandIsland 경유로 읽는 것이 Bandit API상 번거로워 고정 포트를 쓴다).
  @port 41_889

  defmodule StubPlug do
    @moduledoc false
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%Plug.Conn{method: "POST"} = conn, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)

      send(
        test_pid,
        {:otlp_request, %{path: conn.request_path, headers: conn.req_headers, body: body}}
      )

      Plug.Conn.send_resp(conn, 200, "")
    end

    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 404, "")
  end

  defmodule Nodes do
    def start(_state, _ctx), do: %{a: 1}
  end

  setup do
    test_pid = self()

    start_supervised!({Bandit, plug: {StubPlug, test_pid: test_pid}, port: @port, scheme: :http})

    # langfuse_otlp_config/3 가 만드는 바로 그 헤더(Basic auth + x-langfuse-ingestion-version)를
    # exporter app env 에 그대로 적용한다 — 실 Langfuse 송신 경로와 동일.
    headers = Keyword.fetch!(Bridge.langfuse_otlp_config("pk-test", "sk-test"), :otlp_headers)

    Application.stop(:opentelemetry)
    Application.put_env(:opentelemetry_exporter, :otlp_protocol, :http_protobuf)
    Application.put_env(:opentelemetry_exporter, :otlp_endpoint, "http://localhost:#{@port}")
    Application.put_env(:opentelemetry_exporter, :otlp_headers, headers)
    Application.put_env(:opentelemetry, :span_processor, :simple)
    Application.put_env(:opentelemetry, :traces_exporter, :otlp)
    {:ok, _} = Application.ensure_all_started(:opentelemetry_exporter)
    {:ok, _} = Application.ensure_all_started(:opentelemetry)
    :ok = Bridge.attach()

    on_exit(fn ->
      Bridge.detach()
      Application.stop(:opentelemetry)
      Application.put_env(:opentelemetry, :traces_exporter, :none)
    end)

    :ok
  end

  test "real OTLP exporter POSTs to /v1/traces with Langfuse auth headers and a protobuf body" do
    graph =
      ElGraph.new()
      |> ElGraph.state(:a)
      |> ElGraph.add_node(:start, &Nodes.start/2)
      |> ElGraph.compile(entry: :start)

    {:ok, %{a: 1}} = ElGraph.invoke(graph, %{}, thread_id: "lf-export")

    assert_receive {:otlp_request, req}, 5_000

    assert req.path =~ "/v1/traces"

    {_k, auth} = Enum.find(req.headers, fn {k, _v} -> k == "authorization" end)
    assert String.starts_with?(auth, "Basic ")

    assert Enum.any?(req.headers, fn {k, v} ->
             k == "x-langfuse-ingestion-version" and v == "4"
           end),
           "expected x-langfuse-ingestion-version: 4 header, got: #{inspect(req.headers)}"

    {_k, content_type} = Enum.find(req.headers, fn {k, _v} -> k == "content-type" end)
    assert content_type =~ "protobuf"

    # protobuf 디코딩은 하지 않는다 — non-empty 바이너리면 충분.
    assert byte_size(req.body) > 0
  end
end
