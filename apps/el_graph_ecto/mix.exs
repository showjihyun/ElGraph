defmodule ElGraphEcto.MixProject do
  use Mix.Project

  def project do
    [
      app: :el_graph_ecto,
      version: "0.3.0",
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

  # Dialyzer 정적 타입 분석 (SPEC §10). 외부(Ecto/Postgrex)·Mix 내부 경고는
  # `.dialyzer_ignore.exs`로 격리한다(umbrella 자식은 공유 PLT를 재빌드하지 않아
  # `plt_add_apps: [:mix]`가 먹지 않음 — Mix 미적재 false-positive는 ignore로 처리).
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

  defp deps do
    [
      {:el_graph, in_umbrella: true},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.20"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
