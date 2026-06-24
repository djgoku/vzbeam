defmodule VzBeam.AtomicFileTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "vzbeam-af-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "creates parent dirs, writes the file, leaves no temp", %{dir: dir} do
    target = Path.join([dir, "a", "b", "config.json"])
    assert :ok = VzBeam.AtomicFile.write(target, "hello")
    assert File.read!(target) == "hello"
    assert File.ls!(Path.join([dir, "a", "b"])) == ["config.json"]
  end

  test "returns an error when the parent path is occupied by a file", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "occupied"), "x")
    target = Path.join([dir, "occupied", "child.json"])
    assert {:error, _} = VzBeam.AtomicFile.write(target, "data")
  end
end
