defmodule Voyager.MCP.ServerTest do
  use ExUnit.Case, async: true

  alias Voyager.MCP.Server

  test "server_info advertises the Voyager logo as a PNG data URI" do
    assert [%{"src" => "data:image/png;base64," <> data, "mimeType" => "image/png"}] =
             Server.server_info()["icons"]

    assert <<0x89, "PNG", _::binary>> = Base.decode64!(data)
  end
end
