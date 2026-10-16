defmodule Voyager.Services.SSH.OpensshKey do
  @moduledoc false

  alias Voyager.Services.SSH.BcryptPbkdf

  @begin "-----BEGIN OPENSSH PRIVATE KEY-----"
  @end_marker "-----END OPENSSH PRIVATE KEY-----"

  @ciphers %{
    "3des-cbc" => {:des_ede3_cbc, 24, 8, 0},
    "aes128-cbc" => {:aes_128_cbc, 16, 16, 0},
    "aes192-cbc" => {:aes_192_cbc, 24, 16, 0},
    "aes256-cbc" => {:aes_256_cbc, 32, 16, 0},
    "aes128-ctr" => {:aes_128_ctr, 16, 16, 0},
    "aes192-ctr" => {:aes_192_ctr, 24, 16, 0},
    "aes256-ctr" => {:aes_256_ctr, 32, 16, 0},
    "aes128-gcm@openssh.com" => {:aes_128_gcm, 16, 12, 16},
    "aes256-gcm@openssh.com" => {:aes_256_gcm, 32, 12, 16},
    "chacha20-poly1305@openssh.com" => {:chacha20_poly1305, 64, 0, 16}
  }

  @type reason :: :key_bad_passphrase | :key_unsupported_cipher | :key_unreadable

  @spec decrypt(binary(), String.t()) :: {:ok, :public_key.private_key()} | {:error, reason()}
  def decrypt(pem, passphrase) do
    with {:ok, container} <- parse(pem),
         {:ok, cipher} <- fetch_cipher(container.cipher),
         {:ok, plain} <- decrypt_private(cipher, container, passphrase) do
      decode(container, plain)
    end
  end

  defp parse(pem) do
    with [_, body | _] <- String.split(pem, [@begin, @end_marker]),
         {:ok, <<"openssh-key-v1", 0, rest::binary>>} <- Base.decode64(body, ignore: :whitespace),
         {:ok, [cipher, "bcrypt", kdf_options], <<nkeys::32, rest::binary>>} <- strings(rest, 3),
         {:ok, public_keys, rest} <- strings(rest, nkeys),
         {:ok, [encrypted], tag} <- strings(rest, 1),
         {:ok, [salt], <<rounds::32>>} <- strings(kdf_options, 1) do
      {:ok,
       %{
         cipher: cipher,
         salt: salt,
         rounds: rounds,
         public_keys: public_keys,
         encrypted: encrypted,
         tag: tag
       }}
    else
      _ -> {:error, :key_unreadable}
    end
  end

  defp decrypt_private({algorithm, key_len, iv_len, tag_len}, container, passphrase) do
    <<key::binary-size(^key_len), iv::binary-size(^iv_len)>> =
      BcryptPbkdf.derive(passphrase, container.salt, container.rounds, key_len + iv_len)

    with <<tag::binary-size(^tag_len), _::binary>> <- container.tag,
         <<check::32, check::32, _::binary>> = plain <-
           decrypt_blob(algorithm, key, iv, container.encrypted, tag) do
      {:ok, plain}
    else
      _ -> {:error, :key_bad_passphrase}
    end
  end

  defp decrypt_blob(:chacha20_poly1305, <<key::binary-32, _length_key::binary-32>>, _iv, data, tag) do
    poly_key = :crypto.crypto_one_time(:chacha20, key, chacha_iv(0), <<0::256>>, true)

    if :crypto.mac(:poly1305, poly_key, data) == tag,
      do: :crypto.crypto_one_time(:chacha20, key, chacha_iv(1), data, false),
      else: :error
  end

  defp decrypt_blob(algorithm, key, iv, data, tag) when algorithm in [:aes_128_gcm, :aes_256_gcm],
    do: :crypto.crypto_one_time_aead(algorithm, key, iv, data, <<>>, tag, false)

  defp decrypt_blob(algorithm, key, iv, data, _tag),
    do: :crypto.crypto_one_time(algorithm, key, iv, data, false)

  defp chacha_iv(counter), do: <<counter::little-64, 0::64>>

  defp decode(container, plain) do
    body =
      ["openssh-key-v1\0", string("none"), string("none"), string(""), <<length(container.public_keys)::32>>]
      |> Enum.concat(Enum.map(container.public_keys, &string/1))
      |> Enum.concat([string(plain)])
      |> IO.iodata_to_binary()

    case :ssh_file.decode(Enum.join([@begin, Base.encode64(body), @end_marker], "\n"), :openssh_key_v1) do
      [{key, _attrs} | _] -> {:ok, key}
      _ -> {:error, :key_unreadable}
    end
  end

  defp strings(bin, 0), do: {:ok, [], bin}

  defp strings(<<len::32, value::binary-size(len), rest::binary>>, n) do
    with {:ok, values, rest} <- strings(rest, n - 1), do: {:ok, [value | values], rest}
  end

  defp strings(_bin, _n), do: :error

  defp string(value), do: <<byte_size(value)::32, value::binary>>

  defp fetch_cipher(name) do
    with :error <- Map.fetch(@ciphers, name), do: {:error, :key_unsupported_cipher}
  end
end
