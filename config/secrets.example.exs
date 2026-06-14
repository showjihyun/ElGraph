# config/secrets.exs 템플릿 — 복사해서 실제 키를 넣는다:
#   cp config/secrets.example.exs config/secrets.exs
# secrets.exs는 .gitignore에 등록되어 있다. 키를 커밋하지 말 것.
[
  openai_api_key: nil,
  anthropic_api_key: nil,
  gemini_api_key: nil,
  # Langfuse OTLP 연동 (선택) — https://cloud.langfuse.com 프로젝트 설정에서 발급
  langfuse_public_key: nil,
  langfuse_secret_key: nil,
  langfuse_endpoint: "https://cloud.langfuse.com/api/public/otel"
]
