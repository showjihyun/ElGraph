# 통합 테스트(실 API 호출)는 기본 실행에서 제외: mix test --only integration
# 분산 테스트(:peer로 멀티노드 기동, epmd 필요)는 기본 제외: mix test --include distributed
ExUnit.start(exclude: [:integration, :distributed])
