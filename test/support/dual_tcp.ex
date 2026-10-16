defmodule Voyager.Test.DualTcp do
  @moduledoc """
  `:inet_db` TCP module for SSH tests: IPv4 first, IPv6 when the host only resolves
  that way, so the in-VM `:ssh.daemon` can forward `direct-tcpip` to `::1`.
  """

  def getaddrs(host, timer) do
    with {:error, _} <- :inet_tcp.getaddrs(host, timer), do: :inet6_tcp.getaddrs(host, timer)
  end

  def connect(ip, port, opts, timeout) when tuple_size(ip) == 8,
    do: :inet6_tcp.connect(ip, port, opts, timeout)

  def connect(ip, port, opts, timeout), do: :inet_tcp.connect(ip, port, opts, timeout)

  def listen(port, opts) do
    case List.keyfind(opts, :ip, 0) do
      {:ip, ip} when tuple_size(ip) == 8 -> :inet6_tcp.listen(port, opts)
      _ -> :inet_tcp.listen(port, opts)
    end
  end

  defdelegate getserv(port), to: :inet_tcp
  defdelegate translate_ip(ip), to: :inet_tcp
  defdelegate family(), to: :inet_tcp
end
