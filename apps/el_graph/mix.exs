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
      deps: deps()
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
      {:plug, "~> 1.16", only: :test}
    ]
  end
end
