defmodule ElGraph.Sensor do
  @moduledoc """
  환경을 감시하고 시그널을 방출하는 프로세스 (SPEC §5).

  `poll/1`이 주기(`:interval` ms)마다 호출되어 환경을 확인하고, 조건이 맞으면
  시그널을 방출한다. poll은 상태를 들고 다니므로 이전 관측과 비교해 변화를 감지할 수 있다.

      defmodule MyApp.DocsWatch do
        use ElGraph.Sensor, interval: 5_000

        @impl true
        def poll(last_size) do
          size = total_size()
          if last_size && size != last_size do
            {:signal, %ElGraph.Signal{type: "docs.changed", data: %{size: size}}, size}
          else
            {:quiet, size}
          end
        end
      end

      {:ok, _} = MyApp.DocsWatch.start_link(target: my_agent)   # Agent로 시그널 dispatch

  dispatch 대상: `:target`(Agent server — `send_signal` 호출) 또는 `:on_signal`(함수).
  `:interval` 미지정 시 자동 폴링 없이 `tick/1`(수동 트리거)로만 동작한다.
  """

  @type sensor_state :: term()

  @doc "환경을 확인한다. 시그널을 낼지(+다음 상태) 조용히 있을지 결정한다."
  @callback poll(sensor_state()) ::
              {:signal, ElGraph.Signal.t(), sensor_state()} | {:quiet, sensor_state()}

  @doc "초기 센서 상태. 기본 `nil`."
  @callback init_state(opts :: keyword()) :: sensor_state()
  @optional_callbacks init_state: 1

  defmacro __using__(sensor_opts) do
    quote do
      @behaviour ElGraph.Sensor
      @sensor_opts unquote(sensor_opts)

      def start_link(runtime_opts \\ []),
        do: ElGraph.Sensor.start_link(__MODULE__, @sensor_opts, runtime_opts)

      def child_spec(runtime_opts) do
        %{
          id: Keyword.get(runtime_opts, :id, __MODULE__),
          start: {__MODULE__, :start_link, [runtime_opts]}
        }
      end

      @impl ElGraph.Sensor
      def init_state(_opts), do: nil

      defoverridable init_state: 1, child_spec: 1, start_link: 1
    end
  end

  @doc false
  def start_link(module, sensor_opts, runtime_opts) do
    ElGraph.Sensor.Server.start_link({module, sensor_opts, runtime_opts})
  end

  @doc "센서를 동기적으로 한 번 폴링한다 (테스트/수동 트리거)."
  @spec tick(GenServer.server()) :: :ok
  def tick(server), do: GenServer.call(server, :tick)
end
