defmodule ElGraph.Runner do
  @moduledoc """
  호출 단위 실행의 프로세스 래퍼 (SPEC §3.4, §3.9).

  - `start_run/3` — nolink + monitor. 실행 실패를 직접 다루려는 소유자(L3 에이전트)용.
  - `await/2` — 실행 결과 수신.
  - `cancel/2` — 협조적 취소(`:atomics` 플래그 → `ElGraph.Ctx.cancelled?/1`),
    유예시간(`:cancel_timeout`, 기본 5초) 후 brutal kill.

  스트리밍은 `ElGraph.stream/3`을 사용한다 (호출자 link — 고아 실행 방지).
  """

  alias ElGraph.Graph

  defmodule Run do
    @moduledoc "실행 핸들. `ElGraph.Runner.start_run/3`이 반환한다."
    defstruct [:pid, :monitor_ref, :thread_id, :cancel_flag]

    @type t :: %__MODULE__{
            pid: pid() | nil,
            monitor_ref: reference() | nil,
            thread_id: String.t() | nil,
            cancel_flag: :atomics.atomics_ref() | nil
          }
  end

  @doc "그래프 실행을 별도 프로세스(nolink + monitor)로 시작한다."
  @spec start_run(Graph.t(), map() | keyword(), keyword()) :: {:ok, Run.t()}
  def start_run(%Graph{} = graph, input, opts \\ []) do
    owner = self()
    cancel_flag = :atomics.new(1, [])

    thread_id =
      Keyword.get_lazy(opts, :thread_id, fn ->
        Integer.to_string(System.unique_integer([:positive]))
      end)

    run_opts =
      opts
      |> Keyword.put(:cancel_flag, cancel_flag)
      |> Keyword.put(:thread_id, thread_id)
      |> put_introspect(thread_id)

    runner = fn ->
      register_introspection(opts, thread_id)
      result = ElGraph.Executor.run(graph, input, run_opts)
      send(owner, {:el_graph_run, self(), result})
    end

    pid = if Keyword.get(opts, :link, false), do: spawn_link(runner), else: spawn(runner)
    monitor_ref = Process.monitor(pid)

    {:ok,
     %Run{pid: pid, monitor_ref: monitor_ref, thread_id: thread_id, cancel_flag: cancel_flag}}
  end

  @doc """
  체크포인트 재개를 별도 프로세스(nolink + monitor)로 시작한다.

  `ElGraph.resume/2`의 비동기 버전 — 에이전트의 crash-only 복구(SPEC §5)에 쓰인다.
  """
  @spec start_resume(Graph.t(), keyword()) :: {:ok, Run.t()}
  def start_resume(%Graph{} = graph, opts) do
    owner = self()
    cancel_flag = :atomics.new(1, [])
    thread_id = Keyword.fetch!(opts, :thread_id)
    run_opts = opts |> Keyword.put(:cancel_flag, cancel_flag) |> put_introspect(thread_id)

    pid =
      spawn(fn ->
        register_introspection(opts, thread_id)
        send(owner, {:el_graph_run, self(), ElGraph.Executor.resume(graph, run_opts)})
      end)

    monitor_ref = Process.monitor(pid)

    {:ok,
     %Run{pid: pid, monitor_ref: monitor_ref, thread_id: thread_id, cancel_flag: cancel_flag}}
  end

  @doc """
  Registry에 등록된 실행 중 thread 목록 (introspection, SPEC §3.4 / 부록 A-1).

  `start_run/3`에 `:registry` 옵션을 준 실행만 나타나며, 실행 프로세스가 죽으면
  Registry가 자동 정리한다.
  """
  @spec list(atom()) :: [
          %{thread_id: String.t(), pid: pid(), step: non_neg_integer(), active: [atom()]}
        ]
  def list(registry) do
    registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.map(fn {thread_id, pid, progress} ->
      Map.merge(%{thread_id: thread_id, pid: pid}, progress)
    end)
  end

  @doc "실행 중인 thread의 현재 진행 상황: `{:ok, %{pid:, step:, active:}}` 또는 `:not_found`."
  @spec peek(atom(), String.t()) ::
          {:ok, %{pid: pid(), step: non_neg_integer(), active: [atom()]}} | :not_found
  def peek(registry, thread_id) do
    case Registry.lookup(registry, thread_id) do
      [{pid, progress}] -> {:ok, Map.merge(%{pid: pid}, progress)}
      [] -> :not_found
    end
  end

  # 등록은 러너 프로세스 자신이 한다 — 프로세스가 죽으면 Registry가 자동 정리.
  defp register_introspection(opts, thread_id) do
    case Keyword.get(opts, :registry) do
      nil -> :ok
      registry -> Registry.register(registry, thread_id, %{step: 0, active: []})
    end
  end

  defp put_introspect(run_opts, thread_id) do
    case Keyword.get(run_opts, :registry) do
      nil -> run_opts
      registry -> Keyword.put(run_opts, :introspect, {registry, thread_id})
    end
  end

  @doc "실행 결과를 기다린다. 러너가 비정상 종료하면 `{:error, :killed}` 등을 반환한다."
  @spec await(Run.t(), timeout()) :: ElGraph.Executor.result() | {:error, term()}
  def await(%Run{pid: pid, monitor_ref: ref}, timeout \\ 5_000) do
    receive do
      {:el_graph_run, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, :killed} ->
        {:error, :killed}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:run_down, reason}}
    after
      timeout -> {:error, :await_timeout}
    end
  end

  @doc """
  실행을 취소한다. 취소 플래그를 세우고 러너 종료를 기다리며,
  `:cancel_timeout`(기본 5초) 안에 끝나지 않으면 brutal kill 한다.
  """
  @spec cancel(Run.t(), keyword()) :: :ok
  def cancel(%Run{} = run, opts \\ []) do
    timeout = Keyword.get(opts, :cancel_timeout, 5_000)
    :atomics.put(run.cancel_flag, 1, 1)
    watch_ref = Process.monitor(run.pid)

    receive do
      {:DOWN, ^watch_ref, :process, _pid, _reason} -> :ok
    after
      timeout ->
        Process.exit(run.pid, :kill)

        receive do
          {:DOWN, ^watch_ref, :process, _pid, _reason} -> :ok
        end
    end
  end

  @doc false
  @spec stream(Graph.t(), map() | keyword(), keyword()) :: Enumerable.t()
  def stream(%Graph{} = graph, input, opts) do
    Stream.resource(
      fn ->
        # 소비자 프로세스에서 시작 — 이벤트는 소비자 메일박스로 오고, link로 고아 실행을 막는다.
        {:ok, run} =
          start_run(graph, input, Keyword.merge(opts, link: true, event_sink: self()))

        run
      end,
      &stream_next/1,
      &stream_cleanup/1
    )
  end

  defp stream_next({:done, run}), do: {:halt, run}

  defp stream_next(%Run{pid: pid, monitor_ref: ref, thread_id: thread_id} = run) do
    receive do
      {:el_graph_event, %{thread_id: ^thread_id} = payload} ->
        {[payload], run}

      {:el_graph_run, ^pid, result} ->
        {[%{thread_id: thread_id, event: {:done, result}}], {:done, run}}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {[%{thread_id: thread_id, event: {:down, reason}}], {:done, run}}
    end
  end

  defp stream_cleanup({:done, run}), do: stream_cleanup(run)

  defp stream_cleanup(%Run{} = run) do
    Process.demonitor(run.monitor_ref, [:flush])
    Process.unlink(run.pid)
    if Process.alive?(run.pid), do: Process.exit(run.pid, :kill)
    flush_run_messages(run)
  end

  # 조기 중단 시 이미 도착해 있던 이 실행의 메시지를 비운다 — 소비자 메일박스 오염 방지.
  defp flush_run_messages(%Run{pid: pid, thread_id: thread_id} = run) do
    receive do
      {:el_graph_event, %{thread_id: ^thread_id}} -> flush_run_messages(run)
      {:el_graph_run, ^pid, _result} -> flush_run_messages(run)
    after
      0 -> :ok
    end
  end
end
