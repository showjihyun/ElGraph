defmodule ElGraph.Test.RemoteBus do
  @moduledoc """
  분산 `:pg` 버스 멀티노드 테스트용 원격 헬퍼.

  익명 함수는 노드 경계를 넘지 못하므로(코드 로딩), 원격 노드에서 돌릴 로직은 named 모듈로
  둔다 — test/support는 el_graph ebin에 컴파일되어 `:code.get_path()`에 포함되므로
  `:erpc.call`로 add_paths 후 원격에서 그대로 호출된다.

  주의: `:erpc.call`은 단명 워커에서 실행되므로 거기서 `start_link`하면 링크된 프로세스가
  워커 종료 시 같이 죽는다 → 버스/구독은 반드시 **자기 소유 spawn 프로세스** 안에서 시작한다.
  """

  alias ElGraph.Signal.Bus

  @doc """
  원격 노드에서 `scope`/`pattern`을 구독하는 영속 프로세스를 띄운다. 그 프로세스가
  `:pg` scope를 소유(링크)하고 구독한 뒤, 매칭 시그널을 받으면
  (`Agent.send_signal` = `{:"$gen_cast", {:signal, _}}` cast) `reporter`에게 `{:remote_got, signal}` 전달.
  """
  def start_subscriber(scope, pattern, reporter) when is_pid(reporter) do
    pid =
      spawn(fn ->
        {:ok, _} = Bus.start_link(name: scope, transport: :pg)
        :ok = Bus.subscribe(scope, pattern)
        subscriber_loop(reporter)
      end)

    {:ok, pid}
  end

  defp subscriber_loop(reporter) do
    receive do
      {:"$gen_cast", {:signal, signal}} ->
        send(reporter, {:remote_got, signal})
        subscriber_loop(reporter)

      _other ->
        subscriber_loop(reporter)
    end
  end
end
