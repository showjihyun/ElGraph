defmodule ElGraphUmbrella.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/showjihyun/ElGraph"

  def project do
    [
      apps_path: "apps",
      version: @version,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "ElGraph",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs()
    ]
  end

  # 우산 전역 의존성만 — 앱별 의존성은 각 apps/*/mix.exs에 둔다.
  # ex_doc은 루트에서 `mix docs`로 우산 전체 문서를 생성한다(dev 전용).
  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      # 정돈된 가이드/설계 문서만 노출 — 내부 raw 노트(ecosystem-review/DOGFOODING)는 GitHub에 둔다.
      extras: [
        "README.md": [title: "Overview"],
        "CHANGELOG.md": [title: "Changelog"],
        LICENSE: [title: "License"],
        "docs/SPEC.md": [title: "SPEC"],
        "docs/elixir-vs-python-comparison.md": [title: "Elixir vs Python (LangGraph)"],
        "docs/ENVIRONMENT.md": [title: "Environment"],
        "docs/TDD-SPEC.md": [title: "TDD Spec"]
      ],
      groups_for_extras: [
        Guides: ["README.md", "docs/ENVIRONMENT.md"],
        Design: ["docs/SPEC.md", "docs/elixir-vs-python-comparison.md", "docs/TDD-SPEC.md"]
      ]
    ]
  end
end
