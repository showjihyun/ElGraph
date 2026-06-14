import Config

# 우산 공유 설정. el_graph 코어는 컴파일 타임 설정이 없다.

# el_trace 웹(Phoenix) 엔드포인트
config :el_trace, ElTraceWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: ElTraceWeb.ErrorHTML], layout: false],
  pubsub_server: ElTrace.PubSub,
  live_view: [signing_salt: "eltraceLV"]

# 자산 번들 (JS만 — CSS는 priv/static에 직접 둔다)
config :esbuild,
  version: "0.21.5",
  el_trace: [
    args: ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets),
    cd: Path.expand("../apps/el_trace/assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :phoenix, :json_library, Jason

# 내구 체크포인터(Postgres) — mix ecto.* 태스크가 인지하도록.
config :el_graph_ecto, ecto_repos: [ElGraphEcto.Repo]

import_config "#{config_env()}.exs"
