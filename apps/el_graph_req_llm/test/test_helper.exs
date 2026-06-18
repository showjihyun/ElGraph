# 통합 테스트(실 API 호출)는 기본 실행에서 제외: mix test --only integration
ExUnit.start(exclude: [:integration, :distributed])
