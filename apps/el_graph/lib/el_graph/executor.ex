defmodule ElGraph.Executor do
  @moduledoc """
  Superstep(Pregel/BSP) 실행 루프 (SPEC §3.4).

  한 superstep = 활성 항목 실행 → 쓰기 수집 → reducer 병합 → 다음 항목 결정.
  순수 함수형 재귀 루프이며 부수효과는 telemetry와 이벤트 방출뿐이다.

  활성 항목은 `{key, node, input}` — `:send`의 동적 fan-out으로 같은 노드가
  한 superstep에 여러 번 등장할 수 있어 노드 이름이 아닌 key로 구분한다.
  pending writes(SPEC §3.5)는 쓰기와 함께 제어 지시(goto/sends)도 보존해
  재개 시 라우팅까지 복원된다.

  체크포인트 영속 시점은 `:durability` 모드로 조절한다 (SPEC §3.5):
    * `:sync`  (기본) — 매 superstep 동기 영속. 강한 보장.
    * `:async`        — 순서 보장 writer 프로세스에 비동기 적재, 반환 전 flush. 마지막 step 유실 가능.
    * `:exit`         — 매 step 저장 생략, 완료·인터럽트만 영속. 가장 빠름(중간 크래시 복구 불가).
  """

  alias ElGraph.{Checkpoint, Ctx, Graph}

  @default_max_steps 25

  @type result :: {:ok, map()} | {:error, term()} | {:interrupted, map()}

  @spec run(Graph.t(), map(), keyword()) :: result()
  def run(%Graph{} = graph, input, opts \\ []) do
    meta = build_meta(opts)
    entries = [{graph.entry, graph.entry, nil}]

    base = Keyword.get(opts, :initial_state)

    with_span(meta, fn ->
      with_durability(meta, fn meta ->
        with {:ok, state} <- init_state(graph, input, base),
             :ok <- save_checkpoint(meta, 0, state, entries),
             :ok <- check_static_interrupt(meta, 0, state, entries) do
          loop(graph, entries, state, 0, meta)
        end
      end)
    end)
  end

  @doc """
  마지막 체크포인트에서 실행을 이어간다 (SPEC §3.5).

  완료된 thread(`next: []`)는 노드 재실행 없이 최종 상태를 반환한다.
  부분 실패한 superstep의 pending writes는 `run_superstep/5`가 읽어
  완료된 노드를 건너뛴다.
  """
  @spec resume(Graph.t(), keyword()) :: result()
  def resume(%Graph{} = graph, opts) do
    meta = build_meta(opts)
    {mod, config} = meta.checkpointer

    case mod.get(config, meta.thread_id, :latest) do
      {:ok, %Checkpoint{next: [], state: state}} ->
        {:ok, state}

      {:ok, %Checkpoint{} = checkpoint} ->
        with {:ok, checkpoint} <-
               inject_resume_value(meta, checkpoint, Keyword.fetch(opts, :resume)) do
          meta = %{meta | interrupts: checkpoint.interrupts, interrupt_step: checkpoint.step}
          entries = normalize_entries(checkpoint.next)

          with_span(meta, fn ->
            with_durability(meta, fn meta ->
              loop(graph, entries, checkpoint.state, checkpoint.step, meta)
            end)
          end)
        end

      :not_found ->
        {:error, :no_checkpoint}
    end
  end

  @doc """
  주어진 체크포인트 상태에서 실행을 시작한다 (ElTrace time-travel 재개의 진입점).

  `resume/2`가 thread의 최신 체크포인트를 쓰는 반면, 이건 임의 체크포인트(과거 step)를
  받아 그 상태/활성 노드부터 실행한다. `opts`의 `:thread_id`로 분기(fork)할 새 thread를
  지정하면 원래 thread는 보존된다.
  """
  @spec resume_from(Graph.t(), Checkpoint.t(), keyword()) :: result()
  def resume_from(%Graph{} = graph, %Checkpoint{} = checkpoint, opts) do
    meta = build_meta(opts)
    entries = normalize_entries(checkpoint.next)

    with_span(meta, fn ->
      with_durability(meta, fn meta ->
        with :ok <- save_checkpoint(meta, checkpoint.step, checkpoint.state, checkpoint.next) do
          loop(graph, entries, checkpoint.state, checkpoint.step, meta)
        end
      end)
    end)
  end

  # 재개 주입 값은 체크포인트에 누적 저장된다 — 한 노드에 인터럽트가 여러 개면
  # 이전에 주입된 값들도 재실행 시 다시 필요하기 때문 (SPEC §3.6).
  defp inject_resume_value(_meta, checkpoint, :error), do: {:ok, checkpoint}

  defp inject_resume_value(_meta, %Checkpoint{interrupted: nil}, {:ok, _value}),
    do: {:error, :nothing_to_resume}

  defp inject_resume_value(meta, %Checkpoint{interrupted: node} = checkpoint, {:ok, value}) do
    {mod, config} = meta.checkpointer

    checkpoint = %{
      checkpoint
      | interrupts: Map.update(checkpoint.interrupts, node, [value], &(&1 ++ [value])),
        interrupted: nil
    }

    with :ok <- mod.put(config, checkpoint), do: {:ok, checkpoint}
  end

  defp build_meta(opts) do
    %{
      thread_id:
        Keyword.get_lazy(opts, :thread_id, fn ->
          Integer.to_string(System.unique_integer([:positive]))
        end),
      event_sink: Keyword.get(opts, :event_sink),
      checkpointer: Keyword.get(opts, :checkpointer),
      max_steps: Keyword.get(opts, :max_steps, @default_max_steps),
      interrupt_before: Keyword.get(opts, :interrupt_before, []),
      interrupts: %{},
      interrupt_step: nil,
      cancel_flag: Keyword.get(opts, :cancel_flag),
      introspect: Keyword.get(opts, :introspect),
      durability: validate_durability(Keyword.get(opts, :durability, :sync)),
      async_writer: nil
    }
  end

  defp validate_durability(mode) when mode in [:sync, :async, :exit], do: mode

  defp validate_durability(other),
    do:
      raise(ArgumentError, ":durability must be :sync, :async, or :exit, got: #{inspect(other)}")

  defp with_span(meta, fun) do
    :telemetry.span([:el_graph, :invoke], %{thread_id: meta.thread_id}, fn ->
      {fun.(), %{thread_id: meta.thread_id}}
    end)
  end

  # 입력은 베이스(기본값 또는 이전 대화 상태) 위에 reducer를 통해 적용된다.
  # `:initial_state`(thread 정책 fixed, 마찰 7)가 주어지면 defaults 대신 그 위에서 시작한다.
  defp init_state(%Graph{state_def: state_def} = graph, input, base) do
    defaults = Map.new(state_def, fn {key, %{default: default}} -> {key, default} end)
    start = if base, do: Map.merge(defaults, base), else: defaults
    merge_writes(graph, start, [{:__input__, Map.new(input)}])
  end

  # 구버전 체크포인트(노드 atom 목록)와 신버전(엔트리 튜플)을 모두 수용한다.
  defp normalize_entries(entries) do
    Enum.map(entries, fn
      node when is_atom(node) -> {node, node, nil}
      {_key, _node, _input} = entry -> entry
    end)
  end

  defp loop(_graph, [], state, step, meta) do
    finalize(meta, step, state)
    {:ok, state}
  end

  defp loop(_graph, entries, state, step, %{max_steps: max_steps}) when step >= max_steps do
    {:error, {:max_steps_exceeded, %{steps: step, active: entries, state: state}}}
  end

  defp loop(graph, entries, state, step, meta) do
    publish_progress(meta, step, entries)

    case run_superstep(graph, entries, state, step, meta) do
      {:ok, results} ->
        writes = Enum.map(results, fn {_key, node, update, _control} -> {node, update} end)

        # 협조적 취소(SPEC §3.9)는 superstep 경계에서 확인한다 — 노드가 플래그를
        # 보고 일찍 반환한 경우 그 쓰기는 버려지고 실행은 :cancelled로 끝난다.
        with :ok <- check_cancelled(meta),
             {:ok, new_state} <- merge_writes(graph, state, writes),
             {:ok, next} <- next_entries(graph, results, new_state),
             :ok <- save_checkpoint(meta, step + 1, new_state, next),
             :ok <- check_static_interrupt(meta, step + 1, new_state, next) do
          loop(graph, next, new_state, step + 1, meta)
        end

      {:interrupt, node, payload} ->
        dynamic_interrupt(meta, node, payload, entries, state, step)

      {:error, _reason} = error ->
        error
    end
  end

  # introspection (SPEC §3.4): 러너가 Registry에 등록한 진행 상황을 superstep마다 갱신한다.
  defp publish_progress(%{introspect: nil}, _step, _entries), do: :ok

  defp publish_progress(%{introspect: {registry, thread_id}}, step, entries) do
    active = Enum.map(entries, fn {_key, node, _input} -> node end)
    Registry.update_value(registry, thread_id, fn _old -> %{step: step, active: active} end)
    :ok
  end

  defp check_cancelled(%{cancel_flag: nil}), do: :ok

  defp check_cancelled(%{cancel_flag: flag}) do
    if :atomics.get(flag, 1) == 1, do: {:error, :cancelled}, else: :ok
  end

  ## Superstep 실행

  defp run_superstep(graph, entries, state, step, meta) do
    pending = pending_writes(meta, step)
    to_run = Enum.reject(entries, fn {key, _node, _input} -> Map.has_key?(pending, key) end)
    results = exec_all(graph, to_run, state, step, meta)

    successes =
      for {{key, _node, _input}, {:ok, update, control}} <- results, into: %{} do
        {key, {update, control}}
      end

    done = Map.merge(pending, successes)

    halt =
      Enum.find(results, fn {_entry, result} -> match?({:error, _}, result) end) ||
        Enum.find(results, fn {_entry, result} -> match?({:interrupt, _}, result) end)

    case halt do
      nil ->
        {:ok,
         Enum.map(entries, fn {key, node, _input} ->
           {update, control} = Map.fetch!(done, key)
           {key, node, update, control}
         end)}

      {{_key, node, _input}, halt_result} ->
        # 성공한 형제 노드의 쓰기·제어 지시를 보존해 재개 시 재실행(LLM 중복 호출 등)을
        # 막는다 (SPEC §3.5/§3.6). 보존 실패는 재실행 비용일 뿐이므로 원래 결과를 우선한다.
        completed_writes =
          for {key, _node, _input} <- entries, Map.has_key?(done, key) do
            {key, Map.fetch!(done, key)}
          end

        if completed_writes != [], do: persist_writes(meta, step, completed_writes)

        case halt_result do
          {:error, _reason} = error -> error
          {:interrupt, payload} -> {:interrupt, node, payload}
        end
    end
  end

  # 단일 항목은 Task 없이 인라인 실행 — 프로세스는 런타임 이유(병렬)가 있을 때만.
  defp exec_all(_graph, [], _state, _step, _meta), do: []

  defp exec_all(graph, [entry], state, step, meta),
    do: [{entry, exec_node(graph, entry, state, step, meta)}]

  defp exec_all(graph, entries, state, step, meta) do
    # 병렬 노드는 별도 Task에서 돈다 — OTel 컨텍스트는 프로세스 로컬이라 자동 전파되지 않는다.
    # 부모(실행기 프로세스)의 컨텍스트를 캡처해 각 Task에서 attach하면 노드 span이 invoke
    # span 아래로 중첩된다 (OTel 미사용 시 빈 컨텍스트라 무비용·무해, 트렌드 보고서 Tier 1.4).
    otel_ctx = OpenTelemetry.Ctx.get_current()

    entries
    |> Task.async_stream(
      fn entry ->
        OpenTelemetry.Ctx.attach(otel_ctx)
        {entry, exec_node(graph, entry, state, step, meta)}
      end,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, tagged} -> tagged end)
  end

  defp exec_node(%Graph{nodes: nodes} = graph, {_key, node, send_input}, state, step, meta) do
    %{run: run, opts: opts} = Map.fetch!(nodes, node)

    ctx = %Ctx{
      thread_id: meta.thread_id,
      step: step,
      node: node,
      event_sink: meta.event_sink,
      resume_values: resume_values(meta, node, step),
      interrupt_counter: :counters.new(1, []),
      cancel_flag: meta.cancel_flag
    }

    # :send의 입력은 상태가 아니라 send가 지정한 맵이다 (SPEC §3.2).
    input = send_input || node_input(graph, opts, state)
    timeout = Keyword.get(opts, :timeout, :infinity)
    retry = Keyword.get(opts, :retry, [])
    emit_event(meta, step, node, :node_start)
    span_meta = %{node: node, step: step, thread_id: meta.thread_id}

    result =
      :telemetry.span([:el_graph, :node], span_meta, fn ->
        {run_attempts(run, input, ctx, node, timeout, retry, 1), span_meta}
      end)

    emit_event(meta, step, node, :node_end)
    result
  end

  ## 재시도 (SPEC §4)

  defp run_attempts(run, input, ctx, name, timeout, retry, attempt) do
    result = run_with_timeout(run, input, ctx, name, timeout)
    max = Keyword.get(retry, :max, 0)

    case result do
      {:error, reason} when attempt <= max ->
        if retryable?(reason, Keyword.get(retry, :retry_on)) do
          :telemetry.execute(
            [:el_graph, :node, :retry],
            %{attempt: attempt},
            %{
              node: name,
              step: ctx.step,
              thread_id: ctx.thread_id,
              reason: reason,
              attempt: attempt
            }
          )

          backoff_sleep(retry, attempt)
          run_attempts(run, input, ctx, name, timeout, retry, attempt + 1)
        else
          result
        end

      other ->
        other
    end
  end

  defp retryable?({:node_crashed, _node, _reason}, nil), do: true
  defp retryable?({:node_timeout, _node, _ms}, nil), do: true

  defp retryable?({:node_crashed, _node, %exception_mod{}}, allowed) when is_list(allowed),
    do: exception_mod in allowed

  defp retryable?(_reason, _allowed), do: false

  defp backoff_sleep(retry, attempt) do
    case Keyword.get(retry, :backoff, :none) do
      :none -> :ok
      :exponential -> Process.sleep(Keyword.get(retry, :base, 100) * Integer.pow(2, attempt - 1))
    end
  end

  ## 노드 호출

  defp run_with_timeout(run, input, ctx, name, :infinity), do: safe_call(run, input, ctx, name)

  defp run_with_timeout(run, input, ctx, name, timeout) do
    # safe_call 전체(throw catch 포함)를 Task 안에서 돌린다 — 인터럽트 throw가
    # Task 경계를 넘지 않도록. 초과 시 brutal kill (진행 중 HTTP 등은 Task 종료로 정리).
    task = Task.async(fn -> safe_call(run, input, ctx, name) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, {:node_timeout, name, timeout}}
      {:exit, reason} -> {:error, {:node_crashed, name, reason}}
    end
  end

  defp safe_call(run, input, ctx, name) do
    run |> call_node(input, ctx) |> normalize_return(name)
  rescue
    exception -> {:error, {:node_crashed, name, exception}}
  catch
    # SPEC §3.6: throw는 노드 래퍼(Task 내부)에서 잡아 태그 반환으로 변환한다 —
    # uncaught throw가 Task exit으로 변질되지 않게.
    :throw, {:__el_graph_interrupt__, payload} -> {:interrupt, payload}
    :throw, value -> {:error, {:uncaught_throw, name, value}}
  end

  defp call_node({m, f, a}, state, ctx), do: apply(m, f, [state, ctx | a])
  defp call_node(fun, state, ctx) when is_function(fun, 2), do: fun.(state, ctx)

  # 서브그래프 (SPEC §3.10): 부모와 이름이 겹치는 상태 키(공유 채널)로 입출력한다.
  # 내부 체크포인트/인터럽트는 아직 지원하지 않는다 — {:ok, _} 외의 결과는 노드 크래시.
  defp call_node(%Graph{} = subgraph, state, _ctx) do
    shared_input = Map.take(state, Map.keys(subgraph.state_def))

    case run(subgraph, shared_input, []) do
      {:ok, final} -> Map.take(final, Map.keys(state))
      other -> raise ElGraph.SubgraphError, result: other
    end
  end

  # 반환 계약 (SPEC §3.2): map | {:command, goto, update} | [{:send, node, input}]
  defp normalize_return({:command, goto, update}, _name)
       when is_atom(goto) and is_map(update) and not is_struct(update),
       do: {:ok, update, {:goto, goto}}

  defp normalize_return([{:send, _node, _input} | _] = sends, name) do
    if Enum.all?(sends, &match?({:send, node, input} when is_atom(node) and is_map(input), &1)) do
      {:ok, %{}, {:sends, sends}}
    else
      {:error, {:invalid_node_return, name, sends}}
    end
  end

  defp normalize_return(update, _name) when is_map(update) and not is_struct(update),
    do: {:ok, update, nil}

  defp normalize_return(other, name), do: {:error, {:invalid_node_return, name, other}}

  # 재개 주입 값은 인터럽트가 발생했던 step에서만 노드에 전달된다.
  defp resume_values(%{interrupt_step: step, interrupts: interrupts}, node, step),
    do: Map.get(interrupts, node, [])

  defp resume_values(_meta, _node, _step), do: []

  # input projection (SPEC §3.4): 지정된 키만 전달해 병렬 fan-out의 복사 비용을 줄인다.
  defp node_input(_graph, opts, state) do
    case Keyword.get(opts, :input) do
      nil -> state
      keys -> Map.take(state, keys)
    end
  end

  # 생명주기 이벤트는 사용자 emit(SPEC §3.7)과 같은 봉투로 event_sink에 전달된다.
  defp emit_event(%{event_sink: nil}, _step, _node, _event), do: :ok

  defp emit_event(meta, step, node, event) do
    send(
      meta.event_sink,
      {:el_graph_event, %{thread_id: meta.thread_id, step: step, node: node, event: event}}
    )

    :ok
  end

  ## 인터럽트 (SPEC §3.6)

  # 정적 인터럽트는 superstep 완료 후(다음 활성 노드 기준)에만 검사하므로
  # resume이 같은 노드에서 즉시 재인터럽트되지 않는다.
  defp check_static_interrupt(%{interrupt_before: []}, _step, _state, _next), do: :ok

  defp check_static_interrupt(meta, step, state, next) do
    hits =
      for {_key, node, _input} <- next, node in meta.interrupt_before, uniq: true, do: node

    case hits do
      [] ->
        :ok

      hits ->
        # 인터럽트 시점의 체크포인트는 재개를 위해 반드시 영속돼야 한다.
        # :exit 모드는 매 step 저장을 건너뛰므로 여기서 강제 저장한다.
        persist_for_interrupt(meta, step, state, next)
        {:interrupted, %{thread_id: meta.thread_id, step: step, before: hits, state: state}}
    end
  end

  defp dynamic_interrupt(%{checkpointer: nil}, node, payload, _entries, _state, _step) do
    {:error, {:interrupt_requires_checkpointer, node, payload}}
  end

  defp dynamic_interrupt(meta, node, payload, entries, state, step) do
    {mod, config} = meta.checkpointer

    # :async 모드: 큐에 남은 쓰기를 먼저 비워야(flush) 이 인터럽트 체크포인트가
    # 같은 step의 이전(비인터럽트) 쓰기에 덮이지 않는다. 인터럽트는 항상 동기 기록.
    flush_writer(meta)

    :telemetry.execute(
      [:el_graph, :node, :interrupt],
      %{},
      %{node: node, step: step, thread_id: meta.thread_id, payload: payload}
    )

    checkpoint = %Checkpoint{
      thread_id: meta.thread_id,
      step: step,
      state: state,
      next: entries,
      interrupted: node,
      interrupts: meta.interrupts,
      # 재개 후에도 보존되는 인터럽트 발생 기록 (ElTrace #1).
      interrupt_info: %{node: node, payload: payload}
    }

    case mod.put(config, checkpoint) do
      :ok ->
        {:interrupted,
         %{thread_id: meta.thread_id, step: step, node: node, payload: payload, state: state}}

      {:error, _reason} = error ->
        error
    end
  end

  ## 체크포인트 연동 (SPEC §3.5, durability 모드)
  #
  # save_checkpoint: 매 step 루틴 저장. :sync 동기 put, :async writer 적재, :exit 생략.
  # finalize:        완료 시점. :exit만 최종 체크포인트를 강제 영속(나머지는 routine/flush가 처리).
  # persist_for_interrupt: 인터럽트 시점. :exit만 강제 영속(나머지는 routine + flush가 보장).

  defp save_checkpoint(%{checkpointer: nil}, _step, _state, _next), do: :ok
  defp save_checkpoint(%{durability: :exit}, _step, _state, _next), do: :ok

  defp save_checkpoint(%{durability: :async} = meta, step, state, next) do
    send(meta.async_writer, {:put, checkpoint(meta, step, state, next)})
    :ok
  end

  defp save_checkpoint(%{durability: :sync} = meta, step, state, next),
    do: do_put(meta, step, state, next)

  defp finalize(%{checkpointer: nil}, _step, _state), do: :ok
  defp finalize(%{durability: :exit} = meta, step, state), do: do_put(meta, step, state, [])
  defp finalize(_meta, _step, _state), do: :ok

  defp persist_for_interrupt(%{durability: :exit} = meta, step, state, next),
    do: do_put(meta, step, state, next)

  defp persist_for_interrupt(_meta, _step, _state, _next), do: :ok

  defp do_put(%{checkpointer: {mod, config}} = meta, step, state, next),
    do: mod.put(config, checkpoint(meta, step, state, next))

  defp checkpoint(%{thread_id: thread_id}, step, state, next),
    do: %Checkpoint{thread_id: thread_id, step: step, state: state, next: next}

  defp pending_writes(%{checkpointer: nil}, _step), do: %{}

  defp pending_writes(%{checkpointer: {mod, config}, thread_id: thread_id}, step) do
    Map.new(mod.get_writes(config, thread_id, step), fn
      {key, {update, control}} -> {key, {update, control}}
      # M1 형태(제어 지시 없는 쓰기) 정규화
      {key, update} when is_map(update) -> {key, {update, nil}}
    end)
  end

  defp persist_writes(%{checkpointer: nil}, _step, _writes), do: :ok
  defp persist_writes(%{durability: :exit}, _step, _writes), do: :ok

  defp persist_writes(%{durability: :async} = meta, step, writes) do
    send(meta.async_writer, {:put_writes, meta.thread_id, step, writes})
    :ok
  end

  defp persist_writes(
         %{durability: :sync, checkpointer: {mod, config}, thread_id: thread_id},
         step,
         writes
       ),
       do: mod.put_writes(config, thread_id, step, writes)

  ## 비동기 writer (:async) — 순서 보장(FIFO 메일박스), 반환 전 flush, 정상 종료 시 stop.
  # executor 프로세스에 link되어, executor가 죽으면 writer도 죽는다(진행 중 쓰기 유실은 async의 트레이드오프).

  defp with_durability(%{durability: :async, checkpointer: {_mod, _config} = cp} = meta, fun) do
    writer = spawn_link(fn -> writer_loop(cp) end)
    meta = %{meta | async_writer: writer}
    result = fun.(meta)
    flush_writer(meta)
    send(writer, :stop)
    result
  end

  defp with_durability(meta, fun), do: fun.(meta)

  defp flush_writer(%{durability: :async, async_writer: writer}) when is_pid(writer) do
    send(writer, {:flush, self()})

    receive do
      {:flushed, ^writer} -> :ok
    end
  end

  defp flush_writer(_meta), do: :ok

  defp writer_loop({mod, config} = cp) do
    receive do
      {:put, checkpoint} ->
        mod.put(config, checkpoint)
        writer_loop(cp)

      {:put_writes, thread_id, step, writes} ->
        mod.put_writes(config, thread_id, step, writes)
        writer_loop(cp)

      {:flush, from} ->
        send(from, {:flushed, self()})
        writer_loop(cp)

      :stop ->
        :ok
    end
  end

  ## 쓰기 병합

  defp merge_writes(%Graph{state_def: state_def}, state, writes) do
    flat = for {node, update} <- writes, {key, value} <- update, do: {key, node, value}

    with :ok <- validate_keys(state_def, flat),
         :ok <- check_conflicts(state_def, flat) do
      {:ok, apply_writes(state_def, state, flat)}
    end
  end

  defp validate_keys(state_def, flat) do
    case Enum.find(flat, fn {key, _node, _value} -> not Map.has_key?(state_def, key) end) do
      nil -> :ok
      {key, node, _value} -> {:error, {:unknown_state_key, key, node}}
    end
  end

  # SPEC §3.4: reducer 없는 키에 같은 superstep에서 2개 이상 노드가 쓰면 즉시 에러.
  defp check_conflicts(state_def, flat) do
    conflict =
      flat
      |> Enum.group_by(fn {key, _node, _value} -> key end)
      |> Enum.find(fn {key, entries} ->
        length(entries) > 1 and reducer_for(state_def, key) == nil
      end)

    case conflict do
      nil ->
        :ok

      {key, entries} ->
        {:error, {:write_conflict, key, Enum.map(entries, fn {_key, node, _value} -> node end)}}
    end
  end

  defp apply_writes(state_def, state, flat) do
    Enum.reduce(flat, state, fn {key, _node, value}, acc ->
      case reducer_for(state_def, key) do
        nil -> Map.put(acc, key, value)
        reducer -> Map.update!(acc, key, &apply_reducer(reducer, &1, value))
      end
    end)
  end

  defp reducer_for(state_def, key), do: state_def |> Map.fetch!(key) |> Map.fetch!(:reducer)

  defp apply_reducer({m, f, a}, current, value), do: apply(m, f, [current, value | a])
  defp apply_reducer(fun, current, value) when is_function(fun, 2), do: fun.(current, value)

  ## 다음 활성 항목 결정

  defp next_entries(%Graph{} = graph, results, state) do
    results
    |> Enum.reduce_while({:ok, {MapSet.new(), []}}, fn {_key, node, _update, control},
                                                       {:ok, {plain, sends}} ->
      case control_targets(graph, node, control, state) do
        {:ok, targets, new_sends} ->
          {:cont, {:ok, {Enum.into(targets, plain), sends ++ new_sends}}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, {plain, sends}} ->
        plain_entries =
          plain
          |> MapSet.delete(:end)
          |> Enum.sort()
          |> Enum.map(&{&1, &1, nil})

        send_entries =
          sends
          |> Enum.with_index()
          |> Enum.map(fn {{:send, target, input}, index} -> {{target, index}, target, input} end)

        {:ok, plain_entries ++ send_entries}

      {:error, _reason} = error ->
        error
    end
  end

  defp control_targets(graph, node, nil, state) do
    static = Map.get(graph.edges, node, [])

    with {:ok, routed} <- route(graph, node, state) do
      {:ok, static ++ routed, []}
    end
  end

  defp control_targets(_graph, _node, {:goto, :end}, _state), do: {:ok, [], []}

  defp control_targets(%Graph{nodes: nodes}, node, {:goto, target}, _state) do
    if Map.has_key?(nodes, target) do
      {:ok, [target], []}
    else
      {:error, {:invalid_goto, node, target}}
    end
  end

  defp control_targets(%Graph{nodes: nodes}, node, {:sends, sends}, _state) do
    case Enum.find(sends, fn {:send, target, _input} -> not Map.has_key?(nodes, target) end) do
      nil -> {:ok, [], sends}
      {:send, target, _input} -> {:error, {:invalid_send_target, node, target}}
    end
  end

  defp route(%Graph{routers: routers, nodes: nodes}, node, state) do
    case Map.get(routers, node) do
      nil ->
        {:ok, []}

      router ->
        target = call_router(router, state)

        cond do
          target == :end -> {:ok, [:end]}
          Map.has_key?(nodes, target) -> {:ok, [target]}
          true -> {:error, {:invalid_router_target, node, target}}
        end
    end
  end

  defp call_router({m, f, a}, state), do: apply(m, f, [state | a])
  defp call_router(fun, state) when is_function(fun, 1), do: fun.(state)
end
