defmodule ElGraph.Signal.Bus.MultiNodeTest do
  # 실제 멀티노드(:peer) — :pg 버스의 크로스노드 fan-out 검증. epmd 필요.
  #   mix test --include distributed
  use ExUnit.Case
  @moduletag :distributed

  alias ElGraph.Signal
  alias ElGraph.Signal.Bus
  alias ElGraph.Test.RemoteBus

  setup_all do
    {:ok, _} = ensure_distribution()

    {:ok, peer, node} =
      :peer.start(%{
        name: :el_graph_pg_peer,
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-setcookie", Atom.to_charlist(:erlang.get_cookie())]
      })

    # distribution 연결(쿠키 일치). :pg는 연결된 노드 간 멤버십을 동기화한다.
    true = Node.connect(node)

    # 원격 노드가 el_graph/test 모듈을 로드하도록 코드 경로 공유 (제어는 distribution → :erpc).
    :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
    on_exit(fn -> :peer.stop(peer) end)

    %{node: node}
  end

  test "a :pg bus delivers a published signal to a subscriber on a remote node", %{node: node} do
    scope = :"mn_#{System.unique_integer([:positive])}"

    {:ok, _} = Bus.start_link(name: scope, transport: :pg)
    {:ok, _remote} = :erpc.call(node, RemoteBus, :start_subscriber, [scope, "task.*", self()])

    # :pg 멤버십은 비동기 전파 — 원격 구독자가 보일 때까지 폴링 후 발행.
    assert wait_for_member(scope, "task.*", 60)

    :ok = Bus.publish(scope, %Signal{type: "task.assigned", data: %{n: 1}})

    assert_receive {:remote_got, %Signal{type: "task.assigned", data: %{n: 1}, id: id}}, 2_000
    assert is_binary(id)
  end

  defp ensure_distribution do
    case :net_kernel.start([:"el_graph_primary@127.0.0.1", :longnames]) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  defp wait_for_member(_scope, _pattern, 0), do: false

  defp wait_for_member(scope, pattern, tries) do
    case :pg.get_members(scope, pattern) do
      [_ | _] ->
        true

      [] ->
        receive do
        after
          50 -> :ok
        end

        wait_for_member(scope, pattern, tries - 1)
    end
  end
end
