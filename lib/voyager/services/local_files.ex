defmodule Voyager.Services.LocalFiles do
  @moduledoc false

  @spec read(Path.t()) :: {:ok, binary()} | {:error, {:read_failed, {Path.t(), File.posix()}}}
  def read(path) do
    path = Path.expand(path)

    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:read_failed, {path, reason}}}
    end
  end

  @spec write(Path.t(), iodata(), [File.mode()]) ::
          :ok | {:error, {:write_failed, {Path.t(), File.posix()}}}
  def write(path, contents, modes \\ []) do
    path = Path.expand(path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, contents, modes),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, reason} -> {:error, {:write_failed, {path, reason}}}
    end
  end
end
