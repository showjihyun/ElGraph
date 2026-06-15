# 연결 대상: 환경변수(REDIS_HOST/REDIS_PORT) → app env → 기본값.
# 같은 어댑터·같은 :redis 스위트가 Redis와 Valkey 양쪽을 커버한다(RESP 호환) — CI에서
# REDIS_HOST/REDIS_PORT를 Valkey 인스턴스로 가리키면 동일 테스트가 Valkey를 검증한다.
host = System.get_env("REDIS_HOST") || Application.get_env(:el_graph_redis, :host, "localhost")

port =
  (System.get_env("REDIS_PORT") || to_string(Application.get_env(:el_graph_redis, :port, 6379)))
  |> String.to_integer()

# INFO server 출력에서 실제 백엔드(Valkey/Redis)와 버전을 식별한다.
detect_backend = fn ->
  case Redix.command(:el_graph_test_redix, ["INFO", "server"]) do
    {:ok, info} when is_binary(info) ->
      fields = Map.new(Regex.scan(~r/^([a-z_]+):(.+?)\r?$/m, info), fn [_, k, v] -> {k, v} end)
      valkey? = String.contains?(info, "valkey")
      name = if valkey?, do: "Valkey", else: "Redis"
      version = fields["valkey_version"] || fields["redis_version"] || "?"
      "#{name} #{version}"

    _other ->
      "RESP server"
  end
end

# Valkey/Redis가 있으면 연결을 띄우고 FLUSHDB. 없으면 :redis 태그 제외 후 통과.
# sync_connect는 실패 시 호출 프로세스를 같이 죽이므로 쓰지 않고, PING으로 가용성을 확인한다.
db_ok? =
  case Redix.start_link(host: host, port: port, name: :el_graph_test_redix) do
    {:ok, _} ->
      case Redix.command(:el_graph_test_redix, ["PING"], timeout: 2_000) do
        {:ok, "PONG"} ->
          IO.puts("\n[el_graph_redis] validated against #{detect_backend.()} @ #{host}:#{port}\n")
          Redix.command(:el_graph_test_redix, ["FLUSHDB"])
          true

        other ->
          IO.puts("\n[el_graph_redis] Valkey/Redis 미가용 — :redis 테스트 건너뜀. (#{inspect(other)})\n")
          false
      end

    {:error, reason} ->
      IO.puts("\n[el_graph_redis] Valkey/Redis 미가용 — :redis 테스트 건너뜀. (#{inspect(reason)})\n")
      false
  end

if db_ok? do
  ExUnit.start()
else
  ExUnit.start(exclude: [:redis])
end
