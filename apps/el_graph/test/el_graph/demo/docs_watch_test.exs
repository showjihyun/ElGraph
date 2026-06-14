defmodule ElGraph.Demo.DocsWatchTest do
  use ExUnit.Case, async: true

  alias ElGraph.{Sensor, Signal}
  alias ElGraph.Demo.DocsWatch

  test "stays quiet when docs are unchanged" do
    parent = self()
    sensor = start_supervised!({DocsWatch, on_signal: fn s -> send(parent, {:sig, s}) end})

    # init_state가 현재 크기를 잡았고 변경이 없으므로 조용해야 한다.
    assert :ok = Sensor.tick(sensor)
    refute_receive {:sig, _}, 50
  end

  test "emits docs.changed when the seeded size differs from current" do
    parent = self()
    # start: 0으로 시드 → 실제 크기와 달라 첫 tick에서 시그널.
    sensor =
      start_supervised!(
        {DocsWatch, start_size: 0, on_signal: fn s -> send(parent, {:sig, s}) end}
      )

    assert :ok = Sensor.tick(sensor)
    assert_receive {:sig, %Signal{type: "docs.changed", data: %{from: 0, to: to}}}
    assert to > 0
  end
end
