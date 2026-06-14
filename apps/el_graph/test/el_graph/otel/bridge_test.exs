defmodule ElGraph.OTel.BridgeTest do
  use ExUnit.Case, async: true

  alias ElGraph.OTel.Bridge

  describe "langfuse_otlp_config/3" do
    test "builds OTLP/HTTP config with base64 Basic auth from keys" do
      config = Bridge.langfuse_otlp_config("pk-lf-123", "sk-lf-456")

      assert config[:otlp_protocol] == :http_protobuf
      assert config[:otlp_endpoint] == "https://cloud.langfuse.com/api/public/otel"

      headers = config[:otlp_headers]
      assert {"x-langfuse-ingestion-version", "4"} in headers

      auth = Base.encode64("pk-lf-123:sk-lf-456")
      assert {"authorization", "Basic " <> ^auth} = List.keyfind(headers, "authorization", 0)
    end

    test "honors a custom endpoint (e.g. US region)" do
      config =
        Bridge.langfuse_otlp_config("pk", "sk",
          endpoint: "https://us.cloud.langfuse.com/api/public/otel"
        )

      assert config[:otlp_endpoint] == "https://us.cloud.langfuse.com/api/public/otel"
    end
  end

  describe "attach/detach" do
    test "attaching registers a telemetry handler and detach removes it" do
      assert :ok = Bridge.attach()

      handler_ids =
        :telemetry.list_handlers([:el_graph, :invoke, :stop])
        |> Enum.map(& &1.id)

      assert "el-graph-otel-bridge" in handler_ids

      assert :ok = Bridge.detach()

      handler_ids2 =
        :telemetry.list_handlers([:el_graph, :invoke, :stop])
        |> Enum.map(& &1.id)

      refute "el-graph-otel-bridge" in handler_ids2
    end
  end
end
