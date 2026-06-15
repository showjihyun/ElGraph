# 통합 테스트(SDK 전역 상태 의존)는 기본 실행에서 제외: mix test --only integration
ExUnit.start(exclude: [:integration])
