defmodule Voyager.Services.SSH.ErlsshTest do
  # async: false because the test points HOME, which :ssh_file reads for known_hosts, at a tmp dir.
  use ExUnit.Case, async: false

  alias Voyager.Services.SSH.Erlssh
  alias Voyager.Test.SshServer

  setup %{tmp_dir: tmp_dir} do
    home = System.get_env("HOME")
    System.put_env("HOME", tmp_dir)
    on_exit(fn -> System.put_env("HOME", home) end)
  end

  @tag :tmp_dir
  test "does not save the accepted host key to known_hosts", %{tmp_dir: tmp_dir} do
    %{port: port} = SshServer.start!({127, 0, 0, 1})

    assert {:ok, conn} =
             Erlssh.connect(
               "127.0.0.1",
               port,
               SshServer.user(),
               {:password, SshServer.password()}
             )

    Erlssh.close(conn)
    refute File.exists?(Path.join([tmp_dir, ".ssh", "known_hosts"]))
  end
end
