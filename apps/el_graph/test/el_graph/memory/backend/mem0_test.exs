defmodule ElGraph.Memory.Backend.Mem0Test do
  use ExUnit.Case, async: true

  alias ElGraph.Memory.Backend
  alias ElGraph.Memory.Backend.Mem0

  @ns ["users", "u1"]

  defp config(stub), do: {Mem0, [api_key: "k", req_options: [plug: {Req.Test, stub}]]}

  describe "remember/4" do
    test "POSTs the text + user_id with Token auth and returns :ok" do
      Req.Test.stub(Mem0RememberStub, fn conn ->
        assert conn.request_path == "/v1/memories/"
        assert ["Token k"] = Plug.Conn.get_req_header(conn, "authorization")

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["user_id"] == "users:u1"
        assert [%{"role" => "user", "content" => "user upgraded to pro"}] = decoded["messages"]

        Req.Test.json(conn, %{"results" => [%{"id" => "m1", "memory" => "user upgraded to pro"}]})
      end)

      assert :ok = Backend.remember(config(Mem0RememberStub), @ns, "user upgraded to pro")
    end

    test "maps a non-2xx response to {:error, {:api_error, status, body}}" do
      Req.Test.stub(Mem0Err, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"detail" => "bad key"})
      end)

      assert {:error, {:api_error, 401, _}} = Backend.remember(config(Mem0Err), @ns, "x")
    end
  end

  describe "recall/4" do
    test "POSTs the query + user_id and extracts memory texts" do
      Req.Test.stub(Mem0SearchStub, fn conn ->
        assert conn.request_path == "/v1/memories/search/"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["query"] == "what plan?"
        assert decoded["user_id"] == "users:u1"

        Req.Test.json(conn, %{
          "results" => [
            %{"id" => "m1", "memory" => "user is on pro plan", "score" => 0.9},
            %{"id" => "m2", "memory" => "user is in EU", "score" => 0.4}
          ]
        })
      end)

      assert {:ok, ["user is on pro plan", "user is in EU"]} =
               Backend.recall(config(Mem0SearchStub), @ns, "what plan?")
    end

    test "accepts a bare list response shape" do
      Req.Test.stub(Mem0SearchList, fn conn ->
        Req.Test.json(conn, [%{"memory" => "only one"}])
      end)

      assert {:ok, ["only one"]} = Backend.recall(config(Mem0SearchList), @ns, "q")
    end

    test "maps a non-2xx response to {:error, {:api_error, status, body}}" do
      Req.Test.stub(Mem0SearchErr, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"detail" => "boom"})
      end)

      assert {:error, {:api_error, 500, _}} = Backend.recall(config(Mem0SearchErr), @ns, "q")
    end
  end
end
