# OTel 브리지 → Langfuse 실전송 (실 OpenAI + Langfuse)
#   mix run scripts/otel_langfuse.exs
#
# config/secrets.exs에 langfuse_public_key / langfuse_secret_key 필요.
# ElGraph 그래프를 실행하면 telemetry span이 OTel span으로 변환되어 Langfuse로 export된다.
# 실행 후 Langfuse UI의 Traces에서 'invoke_workflow' / 'execute_tool' / 'chat ...' span 확인.

alias ElGraph.OTel.Bridge

secrets =
  if File.exists?("config/secrets.exs") do
    {s, _} = Code.eval_file("config/secrets.exs")
    s
  else
    []
  end

pub = secrets[:langfuse_public_key]
sec = secrets[:langfuse_secret_key]

if is_nil(pub) or is_nil(sec) do
  IO.puts("""
  Langfuse 키가 없습니다. config/secrets.exs에 다음을 채우세요:
    langfuse_public_key: "pk-lf-...",
    langfuse_secret_key: "sk-lf-...",
  키는 cloud.langfuse.com 프로젝트 설정 → API Keys 에서 발급합니다.
  """)

  System.halt(1)
end

endpoint = secrets[:langfuse_endpoint] || "https://cloud.langfuse.com/api/public/otel"
otlp = Bridge.langfuse_otlp_config(pub, sec, endpoint: endpoint)

# OTel을 Langfuse exporter로 (재)구성한다.
Application.stop(:opentelemetry)
Application.put_env(:opentelemetry_exporter, :otlp_protocol, otlp[:otlp_protocol])
Application.put_env(:opentelemetry_exporter, :otlp_endpoint, otlp[:otlp_endpoint])
Application.put_env(:opentelemetry_exporter, :otlp_headers, otlp[:otlp_headers])
Application.put_env(:opentelemetry, :span_processor, :batch)
Application.put_env(:opentelemetry, :traces_exporter, :otlp)
{:ok, _} = Application.ensure_all_started(:opentelemetry_exporter)
{:ok, _} = Application.ensure_all_started(:opentelemetry)

:ok = Bridge.attach()
IO.puts("OTel 브리지 attach 완료. Langfuse: #{endpoint}")

# 실 OpenAI로 ReAct 에이전트 한 번 실행 → span 발생.
llm = {ElGraph.LLM.OpenAI, api_key: ElGraph.Demo.fetch_api_key!()}

graph =
  ElGraph.Presets.react(llm, [ElGraph.Demo.DocsSearch],
    system: "문서를 docs_search로 검색해 한 문장으로 답하라."
  )

IO.puts("그래프 실행 중 (실 OpenAI)...")

{:ok, %{messages: messages, usage: usage}} =
  ElGraph.invoke(graph, %{messages: [ElGraph.LLM.user("ElGraph의 체크포인트는 무엇을 저장해?")]},
    thread_id: "langfuse-demo-#{System.os_time(:second)}"
  )

IO.puts("답변: #{List.last(messages).content}")
IO.puts("tokens in/out: #{usage.input_tokens}/#{usage.output_tokens}")

# batch processor flush 대기 후 종료.
IO.puts("\nspan export flush 대기 (5초)...")

receive do
after
  5_000 -> :ok
end

IO.puts("완료. Langfuse UI → Traces 에서 'invoke_workflow' / 'chat gpt-4o' span을 확인하세요.")
