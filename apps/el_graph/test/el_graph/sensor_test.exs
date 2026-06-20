defmodule ElGraph.SensorTest do
  use ExUnit.Case, async: true

  alias ElGraph.{Sensor, Signal}

  def noop_node(_state, _ctx), do: %{}

  # 폴링 카운터를 들고 다니며 짝수 틱마다 시그널을 낸다.
  defmodule CountingSensor do
    use ElGraph.Sensor

    @impl true
    def init_state(opts), do: Keyword.get(opts, :start, 0)

    @impl true
    def poll(count) do
      count = count + 1

      if rem(count, 2) == 0 do
        {:signal, %Signal{type: "tick.even", data: %{n: count}}, count}
      else
        {:quiet, count}
      end
    end
  end

  defmodule IntervalSensor do
    use ElGraph.Sensor, interval: 20

    @impl true
    def poll(_state), do: {:signal, %Signal{type: "interval.fired", data: %{}}, nil}
  end

  defmodule DriftSensor do
    use ElGraph.Sensor, interval: 40

    @impl true
    def poll(_state) do
      at = System.monotonic_time(:millisecond)

      # poll 작업을 시뮬레이션한다(작업 < interval). 고정주기면 cycle이 interval(40ms)에
      # 고정되고, poll-끝 기준 스케줄(드리프트)이면 cycle ≈ interval + 작업이 된다.
      Process.sleep(25)
      {:signal, %Signal{type: "drift.tick", data: %{at: at}}, nil}
    end
  end

  defmodule PollRaisingSensor do
    use ElGraph.Sensor

    @impl true
    def poll(_state), do: raise("poll boom")
  end

  defmodule DispatchTargetSensor do
    use ElGraph.Sensor

    @impl true
    def poll(_state), do: {:signal, %Signal{type: "fires", data: %{}}, nil}
  end

  describe "Sensor (SPEC §5)" do
    test "tick polls synchronously; emits only when poll returns a signal" do
      parent = self()
      sensor = start_supervised!({CountingSensor, on_signal: fn s -> send(parent, {:got, s}) end})

      assert :ok = Sensor.tick(sensor)
      refute_receive {:got, _}, 50

      assert :ok = Sensor.tick(sensor)
      assert_receive {:got, %Signal{type: "tick.even", data: %{n: 2}}}
    end

    test "init_state seeds the sensor state" do
      parent = self()

      sensor =
        start_supervised!(
          {CountingSensor, start: 1, on_signal: fn s -> send(parent, {:got, s}) end}
        )

      # start 1 → 첫 tick에서 count 2 → 즉시 시그널.
      assert :ok = Sensor.tick(sensor)
      assert_receive {:got, %Signal{data: %{n: 2}}}
    end

    test "dispatches signals to an Agent target via send_signal" do
      defmodule Sink do
        use ElGraph.Agent
        @impl true
        def handle_signal(%Signal{} = s, ctx) do
          send(ctx.opts[:owner], {:agent_got, s})
          :ignore
        end
      end

      graph =
        ElGraph.new()
        |> ElGraph.state(:x)
        |> ElGraph.add_node(:n, &__MODULE__.noop_node/2)
        |> ElGraph.compile(entry: :n)

      agent = start_supervised!({Sink, graph: graph, id: "sink", owner: self()})
      sensor = start_supervised!({CountingSensor, start: 1, target: agent})

      assert :ok = Sensor.tick(sensor)
      assert_receive {:agent_got, %Signal{type: "tick.even"}}
    end

    test "auto-polls on the configured interval" do
      parent = self()
      start_supervised!({IntervalSensor, on_signal: fn s -> send(parent, {:tick, s}) end})

      assert_receive {:tick, %Signal{type: "interval.fired"}}, 500
      assert_receive {:tick, %Signal{type: "interval.fired"}}, 500
    end

    test "auto-poll keeps a fixed rate and does not drift by poll duration" do
      parent = self()
      start_supervised!({DriftSensor, on_signal: fn s -> send(parent, {:at, s.data.at}) end})

      ats =
        for _ <- 1..8 do
          assert_receive {:at, at}, 1_000
          at
        end

      deltas = ats |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)
      median = deltas |> Enum.sort() |> Enum.at(div(length(deltas), 2))

      # 고정주기: cycle ≈ interval(40ms). 드리프트(버그): cycle ≈ interval + 작업 ≈ 65ms.
      # 둘 사이(55ms)로 가른다.
      assert median < 55
    end
  end

  describe "callback isolation (SPEC §5)" do
    test "a raising poll reports via telemetry and keeps the sensor alive" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:el_graph, :sensor, :error]])
      sensor = start_supervised!({PollRaisingSensor, []})

      assert :ok = Sensor.tick(sensor)
      assert_receive {[:el_graph, :sensor, :error], ^ref, %{}, %{sensor: PollRaisingSensor}}

      # 센서가 살아있어 다시 폴링할 수 있어야 한다 (계속 폴링).
      assert :ok = Sensor.tick(sensor)
    end

    test "a raising dispatch reports via telemetry and keeps the sensor alive" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:el_graph, :sensor, :error]])

      sensor =
        start_supervised!(
          {DispatchTargetSensor, on_signal: fn _signal -> raise "dispatch boom" end}
        )

      assert :ok = Sensor.tick(sensor)
      assert_receive {[:el_graph, :sensor, :error], ^ref, %{}, %{sensor: DispatchTargetSensor}}
      assert :ok = Sensor.tick(sensor)
    end
  end
end
