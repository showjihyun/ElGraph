defmodule ElGraph.TestNodes do
  @moduledoc false
  alias ElGraph.Ctx

  def greet(_state, _ctx), do: %{result: "hello"}
  def shout(%{result: result}, _ctx), do: %{result: String.upcase(result)}
  def add_msg(_state, _ctx, msg), do: %{messages: [msg]}
  def inc(_state, _ctx), do: %{count: 1}
  def write_x1(_state, _ctx), do: %{x: 1}
  def write_x2(_state, _ctx), do: %{x: 2}
  def write_unknown(_state, _ctx), do: %{nope: true}
  def seen_keys(state, _ctx), do: %{seen: state |> Map.keys() |> Enum.sort()}
  def noop(_state, _ctx), do: %{}
  def return_garbage(_state, _ctx), do: :oops

  # 의도적으로 항상 raise하는 테스트 헬퍼 — Dialyzer no_return 경고 억제(test 환경 PLT).
  @dialyzer {:nowarn_function, boom: 2}
  def boom(_state, _ctx), do: raise("boom")
  def write_pid(_state, _ctx), do: %{x: self()}

  def emit_token(_state, ctx) do
    Ctx.emit(ctx, {:token, "hi"})
    %{}
  end

  # 호출 횟수를 테스트 소유 ETS 테이블에 기록해 첫 호출만 실패한다.
  # 부분 실패 후 재개(pending writes) 시나리오 전용 — 일반 노드는 순수해야 한다.
  def flaky_b(_state, _ctx, table) do
    if :ets.update_counter(table, :calls, 1, {:calls, 0}) == 1 do
      raise "flaky"
    else
      %{messages: ["b"]}
    end
  end

  def route_until_three(%{count: count}) when count >= 3, do: :end
  def route_until_three(_state), do: :inc

  ## 인터럽트 시나리오용 노드

  def ask(_state, ctx) do
    answer = Ctx.interrupt(ctx, %{question: "name?"})
    %{result: answer}
  end

  def ask_msg(_state, ctx) do
    answer = Ctx.interrupt(ctx, :ask)
    %{messages: [answer]}
  end

  def double_ask(_state, ctx) do
    first = Ctx.interrupt(ctx, :q1)
    second = Ctx.interrupt(ctx, :q2)
    %{result: {first, second}}
  end

  def emit_then_ask(_state, ctx) do
    Ctx.emit(ctx, :before_interrupt)
    answer = Ctx.interrupt(ctx, :ask)
    %{result: answer}
  end

  ## 취소 시나리오용 노드

  def cancel_probe(_state, ctx), do: %{result: Ctx.cancelled?(ctx)}

  # 협조적 노드: 긴 작업을 시뮬레이션하며 주기적으로 취소를 확인한다 (SPEC §3.9).
  def wait_for_cancel(_state, ctx) do
    Ctx.emit(ctx, :running)
    wait_for_cancel_loop(ctx)
  end

  defp wait_for_cancel_loop(ctx) do
    if Ctx.cancelled?(ctx) do
      %{result: :saw_cancel}
    else
      receive do
      after
        5 -> wait_for_cancel_loop(ctx)
      end
    end
  end

  # 비협조적 노드: 취소를 확인하지 않고 영원히 블록 — 유예 후 brutal kill 대상.
  def hang(_state, ctx) do
    Ctx.emit(ctx, :running)

    receive do
      :never -> %{}
    end
  end

  ## 제어 흐름(:command/:send) 시나리오용 노드

  def command_goto(_state, _ctx, goto, update), do: {:command, goto, update}

  def plan_sends(_state, _ctx, items, target) do
    Enum.map(items, fn item -> {:send, target, %{item: item}} end)
  end

  def times_ten(%{item: n}, _ctx), do: %{results: [n * 10]}

  ## 재시도 시나리오용 노드

  # 처음 n번은 실패, 이후 성공 — 호출 횟수를 테스트 소유 ETS에 기록.
  def fail_times(_state, _ctx, table, n) do
    calls = :ets.update_counter(table, :calls, 1, {:calls, 0})

    if calls <= n do
      raise "fail #{calls}"
    else
      %{result: {:ok_after, calls}}
    end
  end

  ## 타임아웃 시나리오용 노드

  def slow(_state, _ctx, sleep_ms) do
    receive do
    after
      sleep_ms -> %{result: :done}
    end
  end

  # 첫 호출만 오래 걸린다(타임아웃 유발), 이후 호출은 즉시 성공 — 재개 시나리오용.
  def slow_once(_state, _ctx, table, sleep_ms) do
    if :ets.update_counter(table, :calls, 1, {:calls, 0}) == 1 do
      receive do
      after
        sleep_ms -> %{messages: ["late"]}
      end
    else
      %{messages: ["b"]}
    end
  end
end
