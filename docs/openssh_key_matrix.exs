alias Voyager.Services.SSH.OpensshKey

[dir] = System.argv()
File.rm_rf!(dir)
File.mkdir_p!(dir)
pass = "test-passphrase"

ciphers = ~w(3des-cbc aes128-cbc aes192-cbc aes256-cbc aes128-ctr aes192-ctr aes256-ctr
             aes128-gcm@openssh.com aes256-gcm@openssh.com chacha20-poly1305@openssh.com)

cases =
  Enum.map(ciphers, &{"ed25519 #{&1}", ["-t", "ed25519", "-a", "1", "-Z", &1]}) ++
    [
      {"ecdsa-256", ["-t", "ecdsa", "-b", "256", "-a", "1"]},
      {"ecdsa-384", ["-t", "ecdsa", "-b", "384", "-a", "1"]},
      {"ecdsa-521", ["-t", "ecdsa", "-b", "521", "-a", "1"]},
      {"rsa-2048", ["-t", "rsa", "-b", "2048", "-a", "1"]},
      {"ed25519 rounds=16", ["-t", "ed25519", "-a", "16"]},
      {"ed25519 rounds=default", ["-t", "ed25519"]},
      {"ed25519 rounds=2", ["-t", "ed25519", "-a", "2"]}
    ]

results =
  for {{name, args}, i} <- Enum.with_index(cases) do
    path = Path.join(dir, "key#{i}")
    {_, 0} = System.cmd("ssh-keygen", ["-q", "-N", pass, "-C", "", "-f", path | args])
    pem = File.read!(path)
    [{expected_pub, _}] = :ssh_file.decode(File.read!(path <> ".pub"), :public_key)

    good =
      case OpensshKey.decrypt(pem, pass) do
        {:ok, key} -> if :ssh_file.extract_public_key(key) == expected_pub, do: :ok, else: :wrong_key
        other -> other
      end

    bad = OpensshKey.decrypt(pem, "wrong-passphrase")
    ok? = good == :ok and bad == {:error, :key_bad_passphrase}
    IO.puts("#{if ok?, do: "PASS", else: "FAIL"}  #{String.pad_trailing(name, 42)} good=#{inspect(good)} bad=#{inspect(bad)}")
    ok?
  end

plain = Path.join(dir, "plain")
{_, 0} = System.cmd("ssh-keygen", ["-q", "-N", "", "-C", "", "-f", plain, "-t", "ed25519"])
IO.puts("unencrypted key: #{inspect(OpensshKey.decrypt(File.read!(plain), pass))}")
IO.puts("#{Enum.count(results, & &1)}/#{length(results)} passed")
