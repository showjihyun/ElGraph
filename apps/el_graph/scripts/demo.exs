# ElGraph 문서 Q&A 도그푸딩 에이전트 (실 OpenAI 사용)
#
#   mix run scripts/demo.exs          # 대화형
#   mix run --no-halt scripts/demo.exs  # 상시 구동 (다른 프로세스가 Demo.ask 호출)
#
# 키: config/secrets.exs 또는 OPENAI_API_KEY 환경변수

{:ok, _pid} = ElGraph.Demo.start_link(reply_to: self())

IO.puts("ElGraph 문서 Q&A 에이전트가 떠 있습니다. 질문을 입력하세요 (빈 줄 입력 시 종료).")

loop = fn loop ->
  case IO.gets("\n> ") do
    :eof ->
      :ok

    line when line in ["\n", "\r\n"] ->
      :ok

    line ->
      ElGraph.Demo.ask(String.trim(line))

      receive do
        {:demo_answer, %{answer: answer}} -> IO.puts("\n#{answer}")
      after
        60_000 -> IO.puts("(60초 안에 답이 오지 않았습니다)")
      end

      loop.(loop)
  end
end

loop.(loop)
