defmodule ElGraph.MixProject do
  use Mix.Project

  def project do
    [
      app: :el_graph,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer()
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
      {:req, "~> 0.5"},
      # OTel 브리지용 — 별도 app(`el_graph_otel`)으로 분리 전까지 in-repo
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_exporter, "~> 1.8"},
      {:opentelemetry_telemetry, "~> 1.1"},
      {:plug, "~> 1.16", only: :test},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
