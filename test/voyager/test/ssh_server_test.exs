defmodule Voyager.Test.SshServerTest do
  use ExUnit.Case, async: true

  alias Voyager.Test.SshServer

  @loopback {127, 0, 0, 1}

  defp connect(port, opts) do
    :ssh.connect(
      @loopback,
      port,
      Keyword.merge(
        [
          user: String.to_charlist(SshServer.user()),
          user_interaction: false,
          silently_accept_hosts: true,
          save_accepted_host: false
        ],
        opts
      )
    )
  end

  defp write_user_key!(dir) do
    key = :public_key.generate_key({:namedCurve, :ed25519})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])
    File.write!(Path.join(dir, "id_ed25519"), pem)
    :ssh_file.extract_public_key(key)
  end

  @tag :tmp_dir
  test "accepts a public key login only for an authorized key", %{tmp_dir: tmp_dir} do
    authorized_dir = Path.join(tmp_dir, "authorized")
    other_dir = Path.join(tmp_dir, "other")
    File.mkdir_p!(authorized_dir)
    File.mkdir_p!(other_dir)
    authorized_key = write_user_key!(authorized_dir)
    write_user_key!(other_dir)

    %{port: port} = SshServer.start!(@loopback, authorized_keys: [authorized_key])
    key_opts = &[user_dir: String.to_charlist(&1), auth_methods: ~c"publickey"]

    assert {:ok, _conn} = connect(port, key_opts.(authorized_dir))
    assert {:error, _reason} = connect(port, key_opts.(other_dir))
  end

  test "returns the host key the client sees" do
    %{port: port, host_key: host_key} = SshServer.start!(@loopback)
    test_pid = self()

    accept = fn _peer, fingerprint ->
      send(test_pid, {:fingerprint, fingerprint})
      true
    end

    assert {:ok, _conn} =
             connect(port,
               password: String.to_charlist(SshServer.password()),
               silently_accept_hosts: {:sha256, accept}
             )

    expected = :ssh.hostkey_fingerprint(:sha256, host_key)
    assert_receive {:fingerprint, ^expected}
  end

  test "reports the process serving each connection" do
    %{port: port} = SshServer.start!(@loopback)

    assert {:ok, conn} = connect(port, password: String.to_charlist(SshServer.password()))
    assert_receive {:ssh_server_connection, server_pid}

    :sys.suspend(server_pid)
    assert {:error, :timeout} = :ssh_connection.session_channel(conn, 200)
    :sys.resume(server_pid)
    assert {:ok, _channel} = :ssh_connection.session_channel(conn, 1_000)
  end
end
