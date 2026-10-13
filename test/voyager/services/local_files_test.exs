defmodule Voyager.Services.LocalFilesTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.LocalFiles

  @moduletag :tmp_dir

  describe "read/1" do
    test "returns the contents of a file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "config")
      File.write!(path, "Host demo\n")

      assert LocalFiles.read(path) == {:ok, "Host demo\n"}
    end

    test "tags a failure with the expanded path", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "missing")

      assert LocalFiles.read(Path.relative_to_cwd(path)) ==
               {:error, {:read_failed, {path, :enoent}}}
    end
  end

  describe "write/3" do
    test "creates missing parent directories", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "voyager", "ssh", "known_hosts"])

      assert LocalFiles.write(path, "host key\n") == :ok
      assert File.read!(path) == "host key\n"
    end

    test "leaves the file accessible only to its owner", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "known_hosts")

      assert LocalFiles.write(path, "host key\n") == :ok
      # Octal: 0o100000 is the regular-file type bit, 0o600 is owner-only read and write.
      assert File.stat!(path).mode == 0o100600
    end

    test "appends when asked to", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "known_hosts")

      assert LocalFiles.write(path, "first\n") == :ok
      assert LocalFiles.write(path, "second\n", [:append]) == :ok
      assert File.read!(path) == "first\nsecond\n"
    end

    test "tags a failure with the expanded path", %{tmp_dir: tmp_dir} do
      parent = Path.join(tmp_dir, "file")
      path = Path.join(parent, "known_hosts")
      File.write!(parent, "")

      assert {:error, {:write_failed, {^path, reason}}} = LocalFiles.write(path, "host key\n")
      assert reason in [:enotdir, :eexist]
    end
  end
end
