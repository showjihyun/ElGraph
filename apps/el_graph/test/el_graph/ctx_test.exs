defmodule ElGraph.CtxTest do
  use ExUnit.Case, async: true

  alias ElGraph.Ctx
  alias ElGraph.Ctx.Internal

  # 공개 함수(emit/interrupt/cancelled?/memo)가 ctx.private(Ctx.Internal)에서 배선을 읽고,
  # private가 없는(실행기 밖 직접 호출) ctx도 안전하게 동작함을 격리 검증한다.

  describe "internal/1 — quarantined wiring" do
    test "defaults to an empty Internal when private is absent" do
      assert %Internal{event_sink: nil, task_cache: nil} = Ctx.internal(%Ctx{node: :n})
    end

    test "returns the set Internal" do
      internal = %Internal{max_concurrency: 4}
      assert ^internal = Ctx.internal(%Ctx{node: :n, private: internal})
    end
  end

  describe "emit/2" do
    test "sends to the private event_sink with public coordinates" do
      ctx = %Ctx{thread_id: "t", step: 2, node: :n, private: %Internal{event_sink: self()}}
      assert :ok = Ctx.emit(ctx, {:token, "hi"})

      assert_received {:el_graph_event,
                       %{thread_id: "t", step: 2, node: :n, event: {:token, "hi"}}}
    end

    test "is a no-op without a private event_sink" do
      assert :ok = Ctx.emit(%Ctx{node: :n}, :anything)
      refute_received {:el_graph_event, _}
    end
  end

  describe "cancelled?/1" do
    test "reads the private cancel_flag" do
      flag = :atomics.new(1, [])
      ctx = %Ctx{node: :n, private: %Internal{cancel_flag: flag}}
      refute Ctx.cancelled?(ctx)
      :atomics.put(flag, 1, 1)
      assert Ctx.cancelled?(ctx)
    end

    test "false without a private cancel_flag" do
      refute Ctx.cancelled?(%Ctx{node: :n})
    end
  end

  describe "memo/3" do
    test "runs the fun without a task cache" do
      assert "x" = Ctx.memo(%Ctx{node: :n}, :k, fn -> "x" end)
    end

    test "caches by node_key from private" do
      tid = :ets.new(:ctx_memo, [:set, :public])
      ctx = %Ctx{node: :n, private: %Internal{node_key: {:n, 0}, task_cache: tid}}
      assert 1 = Ctx.memo(ctx, :k, fn -> 1 end)
      # 두 번째 호출은 캐시 히트 — fun을 다시 돌리지 않는다.
      assert 1 = Ctx.memo(ctx, :k, fn -> 2 end)
    end
  end

  describe "interrupt/2" do
    test "returns an injected resume value matched by call order" do
      ctx = %Ctx{
        node: :n,
        private: %Internal{resume_values: [:first], interrupt_counter: :counters.new(1, [])}
      }

      assert :first = Ctx.interrupt(ctx, %{ask: "?"})
    end

    test "throws the tagged interrupt when there is no resume value" do
      ctx = %Ctx{node: :n, private: %Internal{interrupt_counter: :counters.new(1, [])}}

      assert catch_throw(Ctx.interrupt(ctx, %{ask: "?"})) ==
               {:__el_graph_interrupt__, %{ask: "?"}}
    end
  end
end
