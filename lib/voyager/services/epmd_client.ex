defmodule Voyager.Services.EpmdClient do
  @moduledoc false

  @epmd_names_req 110
  @epmd_timeout 5000

  @spec node_port(:inet.port_number(), String.t()) ::
          {:ok, :inet.port_number()} | {:error, term()}
  def node_port(local_port, node_name) do
    with {:ok, output} <- query_epmd_names(local_port) do
      parse_epmd_names(output, node_name)
    end
  end

  defp query_epmd_names(local_port) do
    opts = [:binary, active: false, packet: :raw]

    with {:ok, sock} <- :gen_tcp.connect(~c"127.0.0.1", local_port, opts, @epmd_timeout) do
      result = send_epmd_request(sock)
      :gen_tcp.close(sock)
      result
    end
  end

  defp send_epmd_request(sock) do
    with :ok <- :gen_tcp.send(sock, <<1::16, @epmd_names_req>>),
         {:ok, resp} <- recv_until_closed(sock, <<>>) do
      parse_names_response(resp)
    end
  end

  # First 4 bytes are epmd's own port; the rest is the "name ... at port N" text.
  defp parse_names_response(<<_epmd_port::32, text::binary>>), do: {:ok, text}
  defp parse_names_response(_), do: {:error, :invalid_epmd_response}

  defp recv_until_closed(sock, acc) do
    case :gen_tcp.recv(sock, 0, @epmd_timeout) do
      {:ok, data} -> recv_until_closed(sock, acc <> data)
      {:error, :closed} -> {:ok, acc}
      {:error, _} = err -> err
    end
  end

  defp parse_epmd_names(output, node_name) do
    case Regex.run(
           ~r/^\s*name\s+#{Regex.escape(node_name)}\s+at\s+port\s+(\d+)\s*$/m,
           output
         ) do
      [_, port] -> {:ok, String.to_integer(port)}
      _ -> {:error, {:node_not_found, node_name, output}}
    end
  end
end
