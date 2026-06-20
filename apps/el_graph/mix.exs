defmodule ElGraph.MixProject do
  use Mix.Project

  def project do
    [
      app: :el_graph,
      version: "0.3.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),
      description:
        "Graph-first agent framework on the BEAM — durable execution, HITL, time-travel, " <>
          "checkpoints, agents, and bidirectional MCP. No Python.",
      source_url: "https://github.com/showjihyun/ElGraph",
      name: "ElGraph",
      docs: [
        main: "readme",
        extras: ["README.md": [title: "Overview"], LICENSE: [title: "License"]],
        source_ref: "v0.3.0"
      ],
      package: package()
    ]
  end

  # hex 패키지 메타데이터(코어). 형제 앱(el_graph_web/ecto/redis/otel, el_trace)도 출시 시 동일 패턴.
  defp package do
    [
      licenses: ["MIT"],
      maintainers: ["Poor Coin Pepe"],
      links: %{
        "GitHub" => "https://github.com/showjihyun/ElGraph",
        "Changelog" => "https://github.com/showjihyun/ElGraph/blob/main/CHANGELOG.md"
      },
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end

  # Dialyzer 정적 타입 분석 (SPEC §10 품질 게이트). PLT는 _build에 캐시.
  # 외부 의존성/사전 존재 경고는 `.dialyzer_ignore.exs`로 격리한다.
  defp dialyzer do
    [
      ignore_warnings: ".dialyzer_ignore.exs",
      flags: [:error_handling, :missing_return]
    ]
  end

  def application do
    [
      # :mnesia — BEAM 내장(외부 의존성 아님). Checkpointer.Mnesia 어댑터용.
      extra_applications: [:logger, :mnesia]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:telemetry, "~> 1.3"},
      {:nimble_options, "~> 1.1"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      # executor의 OTel 컨텍스트 전파용 API only — SDK/exporter/브리지는 `el_graph_otel`이 격리한다 (SPEC §13).
      {:opentelemetry_api, "~> 1.4"},
      {:plug, "~> 1.16", only: :test},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # hexdocs 발행용(`mix hex.publish`의 docs 단계). 코어를 독립 패키지로 출시할 때 필요.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # 벤치마크(`mix run bench/*.exs`) — 동시성 스케일링·superstep 처리량·durability·input projection.
      {:benchee, "~> 1.3", only: :dev, runtime: false}
    ]
  end
end
