# CI & 로컬 통합 인프라

## GitHub Actions (`.github/workflows/ci.yml`)

`push`/`pull_request`(→ `main`)에서 실행. Elixir/OTP는 `erlef/setup-beam`으로 설치하고
`deps` + `_build`(+ Dialyzer PLT)를 캐시한다. 잡 구성:

| Job | 내용 |
|---|---|
| `build_test` | `mix deps.get` → `mix compile --warnings-as-errors` → `mix format --check-formatted` → `mix test`(기본, `:integration` 제외). 이어서 인프라/키가 필요 없는 통합 테스트 두 건(`langfuse_pipeline_test`, `command_integration_test`)을 `--include integration`으로 실행. |
| `dialyzer` | 5개 앱(`el_graph`, `el_graph_web`, `el_trace`, `el_graph_ecto`, `el_graph_redis`) 각각 `mix dialyzer`. |
| `integration` | Postgres 16 + Valkey 8 서비스 컨테이너를 띄우고 `apps/el_graph_ecto`·`apps/el_graph_redis`의 `mix test`를 실행(각각 `:postgres`/`:redis` 계약 스위트). |
| `live_llm` | `OPENAI_API_KEY` 시크릿이 있을 때만 `apps/el_graph`에서 `mix test --only integration` 실행. 시크릿이 없으면 스킵하므로 CI는 그래도 green. |

### DB 접속 env (test_helper가 읽는 값)

- Postgres: `ELGRAPH_PG_HOST/PORT/USER/PASSWORD/DB` (포트 `5433`, `config/test.exs` 기본값).
- Valkey/Redis: redis test_helper는 `REDIS_HOST`/`REDIS_PORT`를 우선 확인하고 없으면 app env
  (`ELGRAPH_REDIS_*`)로 폴백한다. CI는 안전하게 둘 다 `localhost:6380`으로 지정한다.

## 로컬 통합 테스트 (`docker-compose.yml`)

```sh
docker compose up -d                       # Postgres(5433) + Valkey(6380), healthcheck 포함
cd apps/el_graph_ecto && mix test          # :postgres 계약 스위트
cd apps/el_graph_redis && mix test         # :redis 계약 스위트
docker compose down                        # 정리
```

DB가 떠 있지 않으면 각 앱의 `test/test_helper.exs`가 `:postgres`/`:redis` 태그를 자동
제외하므로 일반 `mix test`는 그대로 통과한다.
