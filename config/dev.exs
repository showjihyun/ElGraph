import Config

config :el_trace, ElTraceWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    "el_trace_dev_secret_key_base_0123456789_abcdefghijklmnopqrstuvwxyz_ABCDEFGHIJKLMNOP",
  watchers: [esbuild: {Esbuild, :install_and_run, [:el_trace, ~w(--sourcemap=inline --watch)]}],
  live_reload: [
    patterns: [
      ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/el_trace_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

# 페이지를 열면 곧바로 승인 대기 thread가 보이도록 시드 데이터를 띄운다.
config :el_trace, seed_dev_data: true

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
