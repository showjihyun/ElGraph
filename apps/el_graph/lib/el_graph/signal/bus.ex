defmodule ElGraph.Signal.Bus do
  @moduledoc """
  시그널 라우터/버스 (SPEC §5). 패턴 구독 + fan-out 발행.

  두 transport (`:transport` 옵션, 기본 `:local`):

    * `:local` — Registry 기반(단일 노드). Agent 구독과 함수 구독(변환/로깅) 모두 지원.
    * `:pg` — distributed Erlang `:pg` 기반(클러스터 전체). **Agent 구독만** 분산된다
      — 함수는 노드 경계를 넘지 못하므로 `:pg` 버스에서 함수 구독은 거부된다.

  구독자 프로세스가 죽으면 구독은 자동 정리된다(Registry/`:pg` 모두).
  분산은 best-effort 전달이다 (SPEC §6) — 전달 보장이 필요하면 멱등 수신으로 설계하라.

      children = [{ElGraph.Signal.Bus, name: MyApp.Bus}]                    # 로컬
      children = [{ElGraph.Signal.Bus, name: MyApp.Bus, transport: :pg}]    # 분산
  """

  alias ElGraph.Signal
  alias ElGraph.Signal.Bus.Pg

  @doc false
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "버스를 시작한다 (`:name` 필수, `:transport` 기본 `:local`)."
  def start_link(opts) do
    case Keyword.get(opts, :transport, :local) do
      :local -> Registry.start_link(keys: :duplicate, name: Keyword.fetch!(opts, :name))
      :pg -> Pg.start_link(opts)
    end
  end

  @doc "Agent 구독: 매칭되는 시그널이 호출 프로세스에 `send_signal`로 전달된다."
  @spec subscribe(atom(), String.t()) :: :ok
  def subscribe(bus, pattern) do
    if Pg.started?(bus) do
      Pg.join(bus, pattern)
    else
      {:ok, _owner} = Registry.register(bus, :subscribers, {pattern, :send_signal})
      :ok
    end
  end

  @doc "함수 구독: 매칭되는 시그널로 `fun`이 (발행자 컨텍스트에서) 호출된다. `:local` 전용."
  @spec subscribe(atom(), String.t(), (Signal.t() -> any())) :: :ok
  def subscribe(bus, pattern, fun) when is_function(fun, 1) do
    if Pg.started?(bus) do
      raise ArgumentError,
            "function subscriptions require a :local bus (functions are not distributable)"
    end

    {:ok, _owner} = Registry.register(bus, :subscribers, {pattern, {:fun, fun}})
    :ok
  end

  @doc "시그널을 매칭되는 모든 구독자에게 발행한다 (fan-out)."
  @spec publish(atom(), Signal.t()) :: :ok
  def publish(bus, %Signal{type: type} = signal) do
    if Pg.started?(bus) do
      Pg.publish(bus, signal)

      :telemetry.execute([:el_graph, :bus, :publish], %{subscribers: 0}, %{
        type: type,
        transport: :pg
      })
    else
      matched =
        for {pid, {pattern, target}} <- Registry.lookup(bus, :subscribers),
            Signal.matches?(pattern, type) do
          dispatch(pid, target, signal)
        end

      :telemetry.execute([:el_graph, :bus, :publish], %{subscribers: length(matched)}, %{
        type: type,
        transport: :local
      })
    end

    :ok
  end

  defp dispatch(pid, :send_signal, signal), do: ElGraph.Agent.send_signal(pid, signal)
  defp dispatch(_pid, {:fun, fun}, signal), do: fun.(signal)
end
