defmodule ElGraph.Durability do
  @moduledoc """
  체크포인트 **영속 시점** 정책을 한곳에 모은 seam (SPEC §3.5).

  실행기는 각 영속 지점에서 모드를 모른 채 무조건 이 모듈을 호출한다 — `:sync/:async/:exit`
  (체크포인터 없으면 `:none`) 분기와 비동기 writer 생애, 쓰기 메커니즘(telemetry + 어댑터
  격리)이 전부 여기 산다. 예전엔 이 정책이 실행기의 7개 함수에 흩어져 있었다.

    * `:sync`  (기본) — 매 step 동기 영속. 강한 보장.
    * `:async`        — 순서 보장 writer 프로세스에 적재(FIFO), 세션 종료 전 flush. 마지막 step 유실 가능.
    * `:exit`         — 매 step 저장 생략, 완료(finalize)·인터럽트만 영속. 가장 빠름.
    * `:none`         — 체크포인터 없음. 모든 지점 no-op.

  영속 지점: `on_step`(루틴), `on_finalize`(완료), `on_interrupt`(정적 인터럽트),
  `on_writes`(부분 실패 pending writes), `put_now`(동적 인터럽트·재개값 주입의 강제 동기 기록).
  쓰기 실패(반환 `{:error}`·raise·exit·throw·비계약 반환)는 `[:el_graph, :checkpoint, :error]`
  telemetry로 노출되고, `:sync`는 `{:error}`로 실행을 실패시킨다(`:async/:exit`는 telemetry만).
  """

  alias ElGraph.Checkpoint

  @type mode :: :sync | :async | :exit
  @type checkpointer :: {module(), term()}

  @type t :: %__MODULE__{
          mode: :none | mode(),
          checkpointer: checkpointer() | nil,
          writer: pid() | nil
        }

  defstruct mode: :none, checkpointer: nil, writer: nil

  @doc """
  실행 옵션에서 핸들을 만든다. `:durability` 모드는 항상 검증한다(잘못된 값은 raise) —
  체크포인터가 없으면 유효 모드는 `:none`이 된다.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    mode = validate(Keyword.get(opts, :durability, :sync))
    checkpointer = Keyword.get(opts, :checkpointer)
    %__MODULE__{mode: if(checkpointer, do: mode, else: :none), checkpointer: checkpointer}
  end

  defp validate(mode) when mode in [:sync, :async, :exit], do: mode

  defp validate(other),
    do:
      raise(ArgumentError, ":durability must be :sync, :async, or :exit, got: #{inspect(other)}")

  @doc """
  세션을 연다 — `:async`는 순서 보장 writer(executor에 link)를 띄우고, 종료 시 flush 후 stop한다.
  `fun`에는 열린 핸들이 전달된다(`:async`는 writer pid 포함).
  """
  @spec with_session(t(), (t() -> result)) :: result when result: term()
  def with_session(%__MODULE__{mode: :async, checkpointer: cp} = durability, fun) do
    writer = spawn_link(fn -> writer_loop(cp) end)
    durability = %{durability | writer: writer}
    result = fun.(durability)
    flush(durability)
    send(writer, :stop)
    result
  end

  def with_session(%__MODULE__{} = durability, fun), do: fun.(durability)

  @typedoc "체크포인트 빌더 — 실제로 기록하는 모드에서만 호출돼 빌드 비용(:exit/:none은 0)을 아낀다."
  @type build :: (-> Checkpoint.t())

  @doc "루틴 step 영속: `:sync` 동기 기록, `:async` writer 적재, `:exit`/`:none` 생략(빌드 안 함)."
  @spec on_step(t(), build()) :: :ok | {:error, term()}
  def on_step(%__MODULE__{mode: :sync} = d, build), do: write(d, build.())
  def on_step(%__MODULE__{mode: :async} = d, build), do: enqueue(d, {:put, build.()})
  def on_step(%__MODULE__{}, _build), do: :ok

  @doc "완료 시점 영속: `:exit`만 최종 체크포인트를 강제 기록(나머지는 routine/flush가 처리)."
  @spec on_finalize(t(), build()) :: :ok | {:error, term()}
  def on_finalize(%__MODULE__{mode: :exit} = d, build), do: write(d, build.())
  def on_finalize(%__MODULE__{}, _build), do: :ok

  @doc "정적 인터럽트 시점 영속: `:exit`만 강제 기록(나머지는 routine + flush가 보장)."
  @spec on_interrupt(t(), build()) :: :ok | {:error, term()}
  def on_interrupt(%__MODULE__{mode: :exit} = d, build), do: write(d, build.())
  def on_interrupt(%__MODULE__{}, _build), do: :ok

  @doc "부분 실패 pending writes 영속: `:sync` 동기, `:async` writer 적재, `:exit`/`:none` 생략."
  @spec on_writes(t(), String.t(), non_neg_integer(), [{atom(), term()}]) :: :ok | {:error, term()}
  def on_writes(%__MODULE__{mode: :sync} = d, thread_id, step, writes),
    do: write_writes(d, thread_id, step, writes)

  def on_writes(%__MODULE__{mode: :async} = d, thread_id, step, writes),
    do: enqueue(d, {:put_writes, thread_id, step, writes})

  def on_writes(%__MODULE__{}, _thread_id, _step, _writes), do: :ok

  @doc """
  모드와 무관하게 즉시 동기 기록한다 — 동적 인터럽트/재개값 주입처럼 항상 영속돼야 하는 지점용.
  `:async`는 호출 전에 `flush/1`로 큐를 비워 순서를 보존한다.
  """
  @spec put_now(t(), Checkpoint.t()) :: :ok | {:error, term()}
  def put_now(%__MODULE__{} = d, %Checkpoint{} = cp), do: write(d, cp)

  @doc "`:async` writer 큐를 비운다(반환 보장). 다른 모드는 no-op."
  @spec flush(t()) :: :ok
  def flush(%__MODULE__{mode: :async, writer: writer}) when is_pid(writer) do
    send(writer, {:flush, self()})

    receive do
      {:flushed, ^writer} -> :ok
    end
  end

  def flush(%__MODULE__{}), do: :ok

  ## 내부 — 쓰기 메커니즘 + writer

  defp enqueue(%__MODULE__{writer: writer}, message) do
    send(writer, message)
    :ok
  end

  defp write(%__MODULE__{checkpointer: {mod, config}}, %Checkpoint{} = cp) do
    :telemetry.execute([:el_graph, :checkpoint, :put], %{}, %{
      thread_id: cp.thread_id,
      step: cp.step
    })

    run_write(fn -> mod.put(config, cp) end, cp.thread_id, cp.step)
  end

  defp write_writes(%__MODULE__{checkpointer: {mod, config}}, thread_id, step, writes),
    do: run_write(fn -> mod.put_writes(config, thread_id, step, writes) end, thread_id, step)

  # :async writer — 순서 보장(FIFO 메일박스), flush 응답, 정상 종료 시 stop.
  # executor에 link되어 executor가 죽으면 함께 죽는다(진행 중 쓰기 유실은 async의 트레이드오프).
  defp writer_loop({mod, config} = cp) do
    receive do
      {:put, checkpoint} ->
        run_write(fn -> mod.put(config, checkpoint) end, checkpoint.thread_id, checkpoint.step)
        writer_loop(cp)

      {:put_writes, thread_id, step, writes} ->
        run_write(fn -> mod.put_writes(config, thread_id, step, writes) end, thread_id, step)
        writer_loop(cp)

      {:flush, from} ->
        send(from, {:flushed, self()})
        writer_loop(cp)

      :stop ->
        :ok
    end
  end

  # 쓰기 실패는 조용히 삼키지 않는다. 반환 {:error,_}뿐 아니라 raise/exit/throw하는 어댑터
  # (Postgres SQL.query!, Redis `{:ok,_}=...`)와 비계약 반환을 모두 격리해 {:error, reason}으로
  # 정규화하고 telemetry로 노출한다 — 그러지 않으면 raise가 executor(동기 invoke면 호출자)나
  # writer를 죽인다. :sync는 호출부에서 이 {:error}로 실행을 실패시킨다.
  defp run_write(fun, thread_id, step) do
    case fun.() do
      :ok -> :ok
      {:error, reason} -> write_error(thread_id, step, reason)
      other -> write_error(thread_id, step, {:invalid_checkpointer_return, other})
    end
  rescue
    exception -> write_error(thread_id, step, exception)
  catch
    :exit, reason -> write_error(thread_id, step, {:exit, reason})
    :throw, value -> write_error(thread_id, step, {:throw, value})
  end

  defp write_error(thread_id, step, reason) do
    :telemetry.execute([:el_graph, :checkpoint, :error], %{}, %{
      thread_id: thread_id,
      step: step,
      reason: reason
    })

    {:error, reason}
  end
end
