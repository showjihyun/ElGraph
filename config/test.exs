import Config

config :el_trace, ElTraceWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    "el_trace_test_secret_key_base_0123456789_abcdefghijklmnopqrstuvwxyz_ABCDEFGHIJKLMN",
  server: false

# 테스트는 텔레메트리 핸들러를 각자 setup에서 attach/detach 한다 (앱 자동 attach 비활성).
config :el_trace, attach_telemetry: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
