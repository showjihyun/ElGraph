defmodule ElGraphWeb.TestAgent do
  @moduledoc false
  # 테스트용 작은 ElGraph 그래프: 질문을 받아 토큰을 스트리밍하고 답을 채운다.

  @doc "원격 캡처용 노드 함수 (compile 경고 없음 — durable 계약 도그푸딩)."
  def reply(%{question: q}, ctx) do
    ElGraph.Ctx.emit(ctx, {:token, "echo: " <> q})
    %{answer: "echo: " <> q}
  end

  @doc "테스트 그래프 빌드."
  def graph do
    ElGraph.new()
    |> ElGraph.state(:question)
    |> ElGraph.state(:answer)
    |> ElGraph.add_node(:reply, &__MODULE__.reply/2)
    |> ElGraph.compile(entry: :reply)
  end

  @doc "이름→스펙 레지스트리(라우터 assigns에 주입)."
  def registry do
    %{
      "echo" => %{
        graph: graph(),
        card: [name: "echo", description: "echoes the question", tools: []]
      }
    }
  end
end
