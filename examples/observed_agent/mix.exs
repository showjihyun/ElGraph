defmodule ObservedAgent.MixProject do
  use Mix.Project

  # 우산(apps/) 밖의 독립 프로젝트 — el_graph/el_trace를 "다시 의존성으로 묶어" 쓰는 예제.
  # path 의존성으로 같은 저장소의 두 앱을 끌어온다. git/hex 의존성도 동일하게 동작한다.
  def project do
    [
      app: :observed_agent,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps()
    ]
  end

  def application do
    [
      mod: {ObservedAgent.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:el_graph, path: "../../apps/el_graph"},
      {:el_trace, path: "../../apps/el_trace"}
    ]
  end
end
