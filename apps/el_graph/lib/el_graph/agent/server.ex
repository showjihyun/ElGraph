defmodule ElGraph.Agent.Server do
  @moduledoc false
  # ElGraph.Agent의 GenServer 본체.
  #
  # 그래프 실행은 콜백 밖(Runner, nolink + monitor)에서 돈다 — 실행 중에도
  # 시그널/상태 조회에 응답하고, 실행 크래시가 에이전트를 죽이지 않는다 (SPEC §5).
  # 실행은 에이전트당 한 번에 하나 — 도중 도착한 작업은 큐에서 직렬 처리.
  #
  # thread 정책 (마찰 7):
  #   :per_request (기본) — 매 시그널이 빈 상태에서 시작 (무상태 작업)
  #   {:fixed, id}        — 이전 실행 최종 상태를 이어받아 누적 (대화), checkpointer 필수

  use GenServer

  alias ElGraph.{Checkpoint, Runner}

  def start_link(callback_mod, opts) do
    # fixed 대화는 상태를 이어가야 하므로 checkpointer가 필수다 — 호출자 컨텍스트에서
    # 검증해야 init에서 raise → link EXIT 전파가 되지 않는다.
    if match?({:fixed, _id}, Keyword.get(opts, :thread)) and
         not Keyword.has_key?(opts, :checkpointer) do
      raise ArgumentError, "thread: {:fixed, id} requires a :checkpointer"
    end

    server_opts =
      case Keyword.get(opts, :registry) do
        nil -> []
        registry -> [name: ElGraph.Agent.via(registry, Keyword.fetch!(opts, :id))]
      end

    GenServer.start_link(__MODULE__, {callback_mod, opts}, server_opts)
  end

  @impl GenServer
  def init({callback_mod, opts}) do
    thread = Keyword.get(opts, :thread, :per_request)
    opts = apply_thread_id(opts, thread)
    run_opts = build_run_opts(opts)

    # 버스 구독은 이 프로세스(init) 컨텍스트에서 — Registry가 이 에이전트를 모니터한다.
    subscribe_to_bus(Keyword.get(opts, :subscribe))

    state = %{
      callback: callback_mod,
      id: Keyword.get(opts, :id),
      graph: Keyword.fetch!(opts, :graph),
      run_opts: run_opts,
      thread: thread,
      conv_state: nil,
      context: %{id: Keyword.get(opts, :id), opts: opts},
      run: nil,
      queue: :queue.new()
    }

    {:ok, state, {:continue, :recover}}
  end

  # crash-only 복구 (SPEC §5): 미완료 thread는 재개하고, fixed 대화의 완료 상태는
  # 이어가기 위해 conv_state로 복원한다.
  @impl GenServer
  def handle_continue(:recover, state) do
    case latest_checkpoint(state) do
      {:ok, %Checkpoint{next: next, state: cp_state}} when next != [] ->
        {:ok, run} = Runner.start_resume(state.graph, state.run_opts)
        {:noreply, %{state | run: run, conv_state: maybe_conv(state, cp_state)}}

      {:ok, %Checkpoint{next: [], state: cp_state}} ->
        {:noreply, %{state | conv_state: maybe_conv(state, cp_state)}}

      :none ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_cast({:signal, signal}, state) do
    case state.callback.handle_signal(signal, state.context) do
      :ignore -> {:noreply, state}
      {:run, input} -> {:noreply, start_or_enqueue(state, input)}
    end
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, %{id: state.id, running: state.run != nil, queued: :queue.len(state.queue)}, state}
  end

  @impl GenServer
  def handle_info({:el_graph_run, pid, result}, %{run: %{pid: pid}} = state) do
    Process.demonitor(state.run.monitor_ref, [:flush])
    emit_stop(state, run_status(result))
    state = remember_conversation(state, result)
    state.callback.handle_result(result, state.context)
    {:noreply, dequeue(%{state | run: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{run: %{monitor_ref: ref}} = state) do
    emit_stop(state, :error)
    state.callback.handle_result({:error, {:run_down, reason}}, state.context)
    {:noreply, dequeue(%{state | run: nil})}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp start_or_enqueue(%{run: nil} = state, input) do
    {:ok, run} = Runner.start_run(state.graph, input, run_opts_for(state))
    :telemetry.execute([:el_graph, :agent, :start], %{}, %{agent_id: state.id})
    %{state | run: run}
  end

  defp start_or_enqueue(state, input) do
    %{state | queue: :queue.in(input, state.queue)}
  end

  defp emit_stop(state, status) do
    :telemetry.execute([:el_graph, :agent, :stop], %{}, %{agent_id: state.id, status: status})
  end

  defp run_status({:ok, _}), do: :ok
  defp run_status({:interrupted, _}), do: :interrupted
  defp run_status(_other), do: :error

  defp dequeue(state) do
    case :queue.out(state.queue) do
      {{:value, input}, queue} -> start_or_enqueue(%{state | queue: queue}, input)
      {:empty, _queue} -> state
    end
  end

  # fixed 대화는 이전 최종 상태를 다음 실행의 베이스로 주입한다.
  defp run_opts_for(%{thread: {:fixed, _id}, conv_state: conv} = state) when conv != nil,
    do: Keyword.put(state.run_opts, :initial_state, conv)

  defp run_opts_for(state), do: state.run_opts

  defp remember_conversation(%{thread: {:fixed, _id}} = state, {:ok, final}),
    do: %{state | conv_state: final}

  defp remember_conversation(state, _result), do: state

  defp maybe_conv(%{thread: {:fixed, _id}}, cp_state), do: cp_state
  defp maybe_conv(_state, _cp_state), do: nil

  defp apply_thread_id(opts, {:fixed, id}), do: Keyword.put(opts, :thread_id, id)
  defp apply_thread_id(opts, _per_request), do: opts

  defp subscribe_to_bus(nil), do: :ok
  defp subscribe_to_bus({bus, pattern}), do: ElGraph.Signal.Bus.subscribe(bus, pattern)

  defp subscribe_to_bus(subscriptions) when is_list(subscriptions) do
    Enum.each(subscriptions, fn {bus, pattern} -> ElGraph.Signal.Bus.subscribe(bus, pattern) end)
  end

  # :registry는 에이전트 이름용이므로, 실행 introspection용 Registry는 :run_registry로 받아
  # Runner의 :registry 옵션으로 변환한다.
  defp build_run_opts(opts) do
    run_opts = Keyword.take(opts, [:checkpointer, :thread_id, :max_steps, :event_sink])

    case Keyword.get(opts, :run_registry) do
      nil -> run_opts
      registry -> Keyword.put(run_opts, :registry, registry)
    end
  end

  defp latest_checkpoint(state) do
    with {mod, config} <- Keyword.get(state.run_opts, :checkpointer),
         thread_id when thread_id != nil <- Keyword.get(state.run_opts, :thread_id),
         {:ok, checkpoint} <- mod.get(config, thread_id, :latest) do
      {:ok, checkpoint}
    else
      _no_checkpoint -> :none
    end
  end
end
