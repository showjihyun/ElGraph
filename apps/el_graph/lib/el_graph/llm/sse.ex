defmodule ElGraph.LLM.SSE do
  @moduledoc """
  Server-Sent Events 증분 프레이밍 파서 (LLM 스트리밍, 순수 함수).

  HTTP 응답 바디는 임의 경계로 쪼개져 도착하므로, 상태(버퍼)를 외부에서 들고 다니며
  완성된 `data:` 페이로드만 떼어낸다. `[DONE]` 센티넬은 걸러낸다. 프로바이더별 청크
  해석(델타/usage 추출)은 어댑터(`ElGraph.LLM.OpenAI` 등)의 몫이다.
  """

  @doc """
  버퍼와 새 청크를 받아 `{완성된 data 페이로드 목록, 남은 버퍼}`를 반환한다.

  이벤트는 빈 줄(`\\n\\n`)로 구분되며, 한 이벤트 내 여러 `data:` 줄은 `\\n`으로 잇는다.
  """
  @spec parse(binary(), binary()) :: {[binary()], binary()}
  def parse(buffer, chunk) do
    combined = buffer <> chunk
    {complete, rest} = split_events(combined)
    payloads = complete |> Enum.map(&event_data/1) |> Enum.reject(&(&1 in [nil, "[DONE]"]))
    {payloads, rest}
  end

  # 완성된 이벤트(빈 줄로 끝난)들과 미완성 꼬리를 분리한다.
  defp split_events(text) do
    parts = String.split(text, "\n\n")
    {complete, [rest]} = Enum.split(parts, length(parts) - 1)
    {complete, rest}
  end

  # 한 이벤트 블록에서 data: 줄들을 추출해 잇는다. data가 없으면 nil.
  defp event_data(block) do
    data_lines =
      block
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(fn "data:" <> rest -> String.replace_prefix(rest, " ", "") end)

    case data_lines do
      [] -> nil
      lines -> Enum.join(lines, "\n")
    end
  end
end
