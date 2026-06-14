import Config

# 호스트 앱이 의존성으로 끌어온 el_trace의 Phoenix 엔드포인트를 설정한다.
# (우산 안에서는 우산 config가 이걸 제공했지만, 외부 소비자는 직접 설정해야 한다.)
config :el_trace, ElTraceWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: true,
  secret_key_base:
    "observed_agent_example_secret_key_base_0123456789_abcdefghijklmnopqrstuvwxyz_ABCDEF",
  render_errors: [formats: [html: ElTraceWeb.ErrorHTML], layout: false],
  pubsub_server: ElTrace.PubSub,
  live_view: [signing_salt: "observedLV"]

config :phoenix, :json_library, Jason
