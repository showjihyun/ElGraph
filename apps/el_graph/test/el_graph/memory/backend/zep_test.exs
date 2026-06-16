defmodule ElGraph.Memory.Backend.ZepTest do
  use ExUnit.Case, async: true

  alias ElGraph.Memory.Backend
  alias ElGraph.Memory.Backend.Zep

  @ns ["users", "u1"]

  defp config(stub), do: {Zep, [api_key: "k", req_options: [plug: {Req.Test, stub}]]}

  describe "remember/4" do
    test "POSTs text data + user_id with Api-Key auth and returns :ok" do
      Req.Test.stub(ZepAddStub, fn conn ->
        assert conn.request_path == "/api/v2/graph"
        assert ["Api-Key k"] = Plug.Conn.get_req_header(conn, "authorization")

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["data"] == "user upgraded to pro"
        assert decoded["type"] == "text"
        assert decoded["user_id"] == "users:u1"

        Req.Test.json(conn, %{"uuid" => "ep-1"})
      end)

      assert :ok = Backend.remember(config(ZepAddStub), @ns, "user upgraded to pro")
    end

    test "maps a non-2xx response to {:error, {:api_error, status, body}}" do
      Req.Test.stub(ZepAddErr, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"message" => "unauthorized"})
      end)

      assert {:error, {:api_error, 401, _}} = Backend.remember(config(ZepAddErr), @ns, "x")
    end
  end

  describe "recall/4" do
    test "POSTs the query scoped to edges and extracts edge facts" do
      Req.Test.stub(ZepSearchStub, fn conn ->
        assert conn.request_path == "/api/v2/graph/search"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["query"] == "what plan?"
        assert decoded["user_id"] == "users:u1"
        assert decoded["scope"] == "edges"

        Req.Test.json(conn, %{
          "edges" => [
            %{"fact" => "user is on the pro plan", "name" => "HAS_PLAN"},
            %{"fact" => "user is located in the EU", "name" => "LOCATED_IN"}
          ]
        })
      end)

      assert {:ok, ["user is on the pro plan", "user is located in the EU"]} =
               Backend.recall(config(ZepSearchStub), @ns, "what plan?")
    end

    test "passes the limit through and returns [] when no edges are found" do
      Req.Test.stub(ZepSearchEmpty, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["limit"] == 3
        Req.Test.json(conn, %{"edges" => []})
      end)

      assert {:ok, []} = Backend.recall(config(ZepSearchEmpty), @ns, "q", limit: 3)
    end

    test "maps a non-2xx response to {:error, {:api_error, status, body}}" do
      Req.Test.stub(ZepSearchErr, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "boom"})
      end)

      assert {:error, {:api_error, 500, _}} = Backend.recall(config(ZepSearchErr), @ns, "q")
    end
  end
end
