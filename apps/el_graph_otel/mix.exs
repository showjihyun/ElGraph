defmodule ElGraphOtel.MixProject do
  use Mix.Project

  def project do
    [
      app: :el_graph_otel,
      version: "0.2.0",
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
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # OTel SDK 브리지 — 무거운 OpenTelemetry 의존성을 코어(el_graph)에서 격리한다 (SPEC §13).
  # 코어는 opentelemetry_api 만 유지하고, SDK/exporter/telemetry-bridge는 여기 둔다.
  defp deps do
    [
      {:el_graph, in_umbrella: true},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_exporter, "~> 1.8"},
      {:opentelemetry_telemetry, "~> 1.1"},
      # OTLP 송신 종단 검증용 로컬 스텁 서버 (langfuse_export_test). 테스트 전용.
      {:plug, "~> 1.16", only: :test},
      {:bandit, "~> 1.5", only: :test},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
