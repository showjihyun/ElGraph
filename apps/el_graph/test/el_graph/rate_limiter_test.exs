defmodule ElGraph.RateLimiterTest do
  use ExUnit.Case, async: true

  alias ElGraph.RateLimiter

  describe "rate limiter (SPEC §5)" do
    test "allows up to limit concurrent holders and queues the rest" do
      limiter = start_supervised!({RateLimiter, limit: 2})

      :ok = RateLimiter.acquire(limiter)

      holder2 =
        spawn_link(fn ->
          :ok = RateLimiter.acquire(limiter)

          receive do
            :never -> :ok
          end
        end)

      # 두 슬롯이 찼으므로 세 번째는 블록된다.
      waiter = Task.async(fn -> RateLimiter.acquire(limiter, 5_000) end)
      refute Task.yield(waiter, 50)

      # 테스트 프로세스가 반환하면 대기자가 슬롯을 얻는다.
      :ok = RateLimiter.release(limiter)
      assert :ok = Task.await(waiter)

      Process.exit(holder2, :kill)
    end

    test "with_limit releases the slot even when the function raises" do
      limiter = start_supervised!({RateLimiter, limit: 1})

      assert_raise RuntimeError, fn ->
        RateLimiter.with_limit(limiter, fn -> raise "boom" end)
      end

      # 슬롯이 회수됐으므로 즉시 획득 가능해야 한다.
      waiter = Task.async(fn -> RateLimiter.acquire(limiter, 1_000) end)
      assert :ok = Task.await(waiter)
    end

    test "a crashed holder frees its slot automatically (monitor)" do
      limiter = start_supervised!({RateLimiter, limit: 1})
      test_pid = self()

      holder =
        spawn(fn ->
          :ok = RateLimiter.acquire(limiter)
          send(test_pid, :held)

          receive do
            :die -> exit(:crash)
          end
        end)

      assert_receive :held
      send(holder, :die)

      # 보유자가 죽으면 모니터가 슬롯을 회수한다 — 새 획득이 성공해야 한다.
      waiter = Task.async(fn -> RateLimiter.acquire(limiter, 1_000) end)
      assert :ok = Task.await(waiter)
    end
  end
end
