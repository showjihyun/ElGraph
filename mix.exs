defmodule ElGraphUmbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # 우산 전역 의존성만 — 앱별 의존성은 각 apps/*/mix.exs에 둔다.
  defp deps do
    []
  end
end
