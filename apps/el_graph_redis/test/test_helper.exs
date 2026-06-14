host = Application.get_env(:el_graph_redis, :host, "localhost")
port = Application.get_env(:el_graph_redis, :port, 6379)

# Valkey/Redis가 있으면 연결을 띄우고 FLUSHDB. 없으면 :redis 태그 제외 후 통과.
# sync_connect는 실패 시 호출 프로세스를 같이 죽이므로 쓰지 않고, PING으로 가용성을 확인한다.
db_ok? =
  case Redix.start_link(host: host, port: port, name: :el_graph_test_redix) do
    {:ok, _} ->
      case Redix.command(:el_graph_test_redix, ["PING"], timeout: 2_000) do
        {:ok, "PONG"} ->
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
