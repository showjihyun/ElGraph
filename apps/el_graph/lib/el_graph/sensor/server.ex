defmodule ElGraph.Sensor.Server do
  @moduledoc false
  # ElGraph.Sensor의 GenServer 본체. interval마다 self로 :poll을 보내고,
  # poll 콜백 결과가 시그널이면 dispatch한다. tick은 같은 폴링을 동기로 수행한다.

  use GenServer

  def start_link({_module, _sensor_opts, runtime_opts} = arg) do
    GenServer.start_link(__MODULE__, arg, Keyword.take(runtime_opts, [:name]))
  end

  @impl GenServer
  def init({module, sensor_opts, runtime_opts}) do
    state = %{
      module: module,
      interval: Keyword.get(sensor_opts, :interval),
      sensor_state: module.init_state(runtime_opts),
      dispatch: build_dispatch(runtime_opts)
    }

    schedule(state.interval)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    state = do_poll(state)
    schedule(state.interval)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:tick, _from, state), do: {:reply, :ok, do_poll(state)}

  # poll/dispatch는 사용자 콜백이므로 격리한다 — 일시적 오류(네트워크 blip 등)에 센서가
  # 죽으면 sensor_state(커서/타임스탬프 등)를 잃고 폴링이 멈춘다. 오류는 telemetry로 알리고
  # 직전 상태를 보존한 채 계속 폴링한다(다음 주기 재시도; at-least-once + 멱등 수신, SPEC §6).
  defp do_poll(state) do
    run_poll(state)
  rescue
    error ->
      :telemetry.execute([:el_graph, :sensor, :error], %{}, %{sensor: state.module, error: error})
      state
  end

  defp run_poll(state) do
    case state.module.poll(state.sensor_state) do
      {:signal, signal, next} ->
        :telemetry.execute(
          [:el_graph, :sensor, :signal],
          %{},
          %{sensor: state.module, signal_type: signal.type}
        )

        state.dispatch.(signal)
        %{state | sensor_state: next}

      {:quiet, next} ->
        %{state | sensor_state: next}
    end
  end

  defp schedule(nil), do: :ok
  defp schedule(interval), do: Process.send_after(self(), :poll, interval)

  # 시그널 dispatch 대상: 함수 우선, 없으면 Agent target, 둘 다 없으면 no-op.
  defp build_dispatch(opts) do
    cond do
      on_signal = opts[:on_signal] -> on_signal
      target = opts[:target] -> &ElGraph.Agent.send_signal(target, &1)
      true -> fn _signal -> :ok end
    end
  end
end
