defmodule ElGraphWeb.SSE do
  @moduledoc """
  Server-Sent Events 프레임 인코딩 (순수).

  맵을 `data: <json>\\n\\n` 한 프레임으로 직렬화한다. AG-UI 이벤트 스트리밍에 쓴다.
  """

  @doc "이벤트 맵을 SSE data 프레임(iodata)으로 인코딩한다."
  @spec encode(map()) :: iodata()
  def encode(event) when is_map(event), do: ["data: ", Jason.encode_to_iodata!(event), "\n\n"]
end
