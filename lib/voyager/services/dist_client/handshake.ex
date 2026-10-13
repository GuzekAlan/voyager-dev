defmodule Voyager.Services.DistClient.Handshake do
  @moduledoc false

  import Bitwise

  @mandatory_25 0x04 ||| 0x10 ||| 0x80 ||| 0x100 ||| 0x200 ||| 0x400 ||| 0x800 |||
                  0x10000 ||| 0x20000 ||| 0x40000 ||| 0x1000000
  @mandatory_26 0x2000000 ||| 0x04 <<< 32
  # erts only sends MONITOR_P_EXIT to peers advertising both DIST_MONITOR and DIST_MONITOR_NAME.
  @dist_monitor 0x08 ||| 0x20
  # DFLAG_SPAWN is left out so the remote's spawn_request towards us fails with notsup.
  @flags @mandatory_25 ||| @mandatory_26 ||| @dist_monitor

  @doc "Version 6 (OTP 23+) handshake as a hidden node on a `{:packet, 2}` socket."
  @spec run(:gen_tcp.socket(), String.t(), String.t(), non_neg_integer(), timeout()) ::
          {:ok, remote_name :: String.t()} | {:error, term()}
  def run(socket, me, cookie, creation, timeout) do
    with :ok <- :gen_tcp.send(socket, send_name(me, creation)),
         {:ok, status} <- recv(socket, timeout),
         :ok <- check_status(status),
         {:ok, challenge_msg} <- recv(socket, timeout),
         {:ok, challenge, remote_name} <- parse_challenge(challenge_msg),
         mine = :rand.uniform(0xFFFFFFFE),
         :ok <- :gen_tcp.send(socket, <<?r, mine::32, digest(cookie, challenge)::binary>>) do
      expected = digest(cookie, mine)

      case recv(socket, timeout) do
        {:ok, <<?a, ^expected::binary-size(16)>>} -> {:ok, remote_name}
        {:ok, _other} -> {:error, :bad_cookie}
        {:error, :closed} -> {:error, :bad_cookie}
        {:error, _} = error -> error
      end
    end
  end

  @spec random_creation() :: non_neg_integer()
  def random_creation, do: 4 + :rand.uniform(0xFFFFFFF0)

  defp send_name(me, creation) do
    <<?N, @flags::64, creation::32, byte_size(me)::16, me::binary>>
  end

  defp check_status(<<?s, "ok">>), do: :ok
  defp check_status(<<?s, status::binary>>), do: {:error, {:handshake_failed, status}}
  defp check_status(_other), do: {:error, {:handshake_failed, :unexpected}}

  defp parse_challenge(
         <<?N, _flags::64, challenge::32, _cre::32, len::16, name::binary-size(len)>>
       ),
       do: {:ok, challenge, name}

  defp parse_challenge(_other), do: {:error, {:handshake_failed, :unexpected}}

  defp recv(socket, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, data} -> {:ok, data}
      {:error, :timeout} -> {:error, {:handshake_failed, :timeout}}
      {:error, _} = error -> error
    end
  end

  defp digest(cookie, challenge), do: :erlang.md5([cookie, Integer.to_string(challenge)])
end
