defmodule ElGraphReqLLM.MixProject do
  use Mix.Project

  def project do
    [
      app: :el_graph_req_llm,
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
        "ReqLLM-backed LLM adapter for ElGraph — one adapter, ~21 providers / 1000+ models.",
      source_url: "https://github.com/showjihyun/ElGraph",
      package: package()
    ]
  end

  # Dialyzer 정적 타입 분석 (SPEC §10). req_llm은 이 앱의 일반 의존성이라 PLT에 포함된다.
  defp dialyzer do
    [
      ignore_warnings: ".dialyzer_ignore.exs",
      flags: [:error_handling, :missing_return]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:el_graph, in_umbrella: true},
      # 일반(비-optional) 의존성 — 어댑터가 ReqLLM 구조체/함수를 컴파일 타임에 참조하므로
      # 이 앱에서는 항상 존재해야 한다. (코어 el_graph는 req_llm을 모른다.)
      {:req_llm, "~> 1.6"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # hex 패키지 메타데이터. 출시 시 {:el_graph, in_umbrella: true} → {:el_graph, "~> 0.3"} 로
  # 교체해야 hex.publish 가능(Hex는 umbrella/path 의존성 거부). 코어(el_graph) 우선 출시 후.
  defp package do
    [
      licenses: ["MIT"],
      maintainers: ["Poor Coin Pepe"],
      links: %{"GitHub" => "https://github.com/showjihyun/ElGraph"},
      files: ~w(lib mix.exs)
    ]
  end
end
