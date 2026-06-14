defmodule ElGraph.Demo.DocsWatch do
  @moduledoc """
  도그푸딩 센서: `docs/*.md`의 총 바이트 크기를 주기 폴링해 변하면 시그널을 낸다.

  변경 시 `"docs.changed"` 시그널(`data: %{from:, to:}`)을 target으로 dispatch.
  정기 점검(폴링) 센서의 표본 — Sensor + Agent 조합의 도그푸딩 3호.
  """

  use ElGraph.Sensor, interval: 3_000

  alias ElGraph.Signal

  @impl true
  def init_state(opts), do: Keyword.get(opts, :start_size, total_size())

  @impl true
  def poll(last_size) do
    size = total_size()

    if last_size != nil and size != last_size do
      {:signal,
       %Signal{type: "docs.changed", source: "docs_watch", data: %{from: last_size, to: size}},
       size}
    else
      {:quiet, size}
    end
  end

  defp total_size do
    ElGraph.Demo.docs_glob()
    |> Path.wildcard()
    |> Enum.map(&File.stat!(&1).size)
    |> Enum.sum()
  end
end
