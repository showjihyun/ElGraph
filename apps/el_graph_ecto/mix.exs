defmodule ElGraphEcto.MixProject do
  use Mix.Project

  def project do
    [
      app: :el_graph_ecto,
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
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:el_graph, in_umbrella: true},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.20"}
    ]
  end
end
