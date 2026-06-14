defmodule ElGraphWeb.SSETest do
  use ExUnit.Case, async: true

  alias ElGraphWeb.SSE

  describe "encode/1" do
    test "encodes a map as a JSON data frame" do
      assert "data: {\"type\":\"PING\"}\n\n" =
               IO.iodata_to_binary(SSE.encode(%{"type" => "PING"}))
    end

    test "produces valid framing terminated by a blank line" do
      frame = IO.iodata_to_binary(SSE.encode(%{"a" => 1}))
      assert String.starts_with?(frame, "data: ")
      assert String.ends_with?(frame, "\n\n")
    end
  end
end
