defmodule ElTrace.MixProject do
  use Mix.Project

  def project do
    [
      app: :el_trace,
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
        "Real-time observability and HITL UI for ElGraph — a Phoenix LiveView timeline " <>
          "with interrupt approval and time-travel fork.",
      source_url: "https://github.com/showjihyun/ElGraph",
      package: package()
    ]
  end

  # Dialyzer 정적 타입 분석 (SPEC §10). Phoenix/LiveView 매크로 생성 코드의
  # 불가피한 경고는 `.dialyzer_ignore.exs`로 격리한다.
  defp dialyzer do
    [
      ignore_warnings: ".dialyzer_ignore.exs",
      flags: [:error_handling, :missing_return]
    ]
  end

  # hex 패키지 메타데이터. 출시 시 {:el_graph, in_umbrella: true} → {:el_graph, "~> 0.3"} 로
  # 교체해야 hex.publish 가능(Hex는 umbrella/path 의존성 거부). 코어(el_graph) 우선 출시 후 형제 앱.
  defp package do
    [
      licenses: ["MIT"],
      maintainers: ["Poor Coin Pepe"],
      links: %{"GitHub" => "https://github.com/showjihyun/ElGraph"},
      files: ~w(lib mix.exs README.md)
    ]
  end

  def application do
    [
      mod: {ElTrace.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:el_graph, in_umbrella: true},
      {:phoenix, "~> 1.7.14"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:phoenix_pubsub, "~> 2.1"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:esbuild, "~> 0.8", only: :dev},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
