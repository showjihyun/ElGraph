import Config

config :el_trace, ElTraceWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    "el_trace_test_secret_key_base_0123456789_abcdefghijklmnopqrstuvwxyz_ABCDEFGHIJKLMN",
  server: false

# 테스트는 텔레메트리 핸들러를 각자 setup에서 attach/detach 한다 (앱 자동 attach 비활성).
config :el_trace, attach_telemetry: false

# 내구 체크포인터 어댑터 테스트용 DB (docker-compose의 Postgres/Valkey).
# DB 미가용 시 각 앱의 test_helper가 해당 태그(:postgres/:redis)를 제외한다.
config :el_graph_ecto, ElGraphEcto.Repo,
  username: System.get_env("ELGRAPH_PG_USER", "postgres"),
  password: System.get_env("ELGRAPH_PG_PASSWORD", "postgres"),
  hostname: System.get_env("ELGRAPH_PG_HOST", "localhost"),
  port: String.to_integer(System.get_env("ELGRAPH_PG_PORT", "5433")),
  database: System.get_env("ELGRAPH_PG_DB", "el_graph_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

config :el_graph_redis,
  host: System.get_env("ELGRAPH_REDIS_HOST", "localhost"),
  port: String.to_integer(System.get_env("ELGRAPH_REDIS_PORT", "6380"))

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
