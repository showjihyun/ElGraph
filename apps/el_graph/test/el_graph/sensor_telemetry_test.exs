defmodule ElGraph.SensorTelemetryTest do
  use ExUnit.Case, async: true

  alias ElGraph.{Sensor, Signal}

  defmodule FiringSensor do
    use ElGraph.Sensor

    @impl true
    def poll(_state), do: {:signal, %Signal{type: "docs.changed", data: %{}}, nil}
  end

  defmodule QuietSensor do
    use ElGraph.Sensor

    @impl true
    def poll(state), do: {:quiet, state}
  end

  describe "sensor telemetry (SPEC §5)" do
    test "emits a sensor.signal event with the module and signal type when a sensor fires" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:el_graph, :sensor, :signal]])
      sensor = start_supervised!({FiringSensor, on_signal: fn _ -> :ok end})

      assert :ok = Sensor.tick(sensor)

      assert_receive {[:el_graph, :sensor, :signal], ^ref, %{},
                      %{sensor: FiringSensor, signal_type: "docs.changed"}}
    end

    test "emits no event when a sensor stays quiet" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:el_graph, :sensor, :signal]])
      sensor = start_supervised!({QuietSensor, on_signal: fn _ -> :ok end})

      assert :ok = Sensor.tick(sensor)

      # 핸들러는 전역이라 다른 테스트의 센서 이벤트가 올 수 있다 — 자기 모듈만 부재 검증.
      refute_receive {[:el_graph, :sensor, :signal], ^ref, _, %{sensor: QuietSensor}}, 50
    end
  end
end
