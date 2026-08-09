defmodule VzBeam.DiskTest do
  use ExUnit.Case, async: true
  alias VzBeam.Disk

  @gb 1024 * 1024 * 1024

  setup do
    dir = Path.join(System.tmp_dir!(), "vzbeam-disk-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, img: Path.join(dir, "disk.img")}
  end

  test "create_sparse makes a file of the apparent size", %{img: img} do
    assert :ok = Disk.create_sparse(img, 2 * @gb)
    assert File.stat!(img).size == 2 * @gb
  end

  test "grow enlarges, no-ops on equal, and preserves existing bytes", %{img: img} do
    File.write!(img, "DATA")
    assert :ok = Disk.grow(img, 1 * @gb)
    assert File.stat!(img).size == 1 * @gb
    assert :ok = Disk.grow(img, 1 * @gb)
    assert binary_part(File.read!(img), 0, 4) == "DATA"
  end

  test "grow refuses to shrink", %{img: img} do
    assert :ok = Disk.create_sparse(img, 2 * @gb)
    assert {:error, {:shrink, have}} = Disk.grow(img, 1 * @gb)
    assert have == 2 * @gb
  end

  test "grow on a missing file returns enoent", %{img: img} do
    assert {:error, :enoent} = Disk.grow(img, @gb)
  end

  test "size and gb formatting", %{img: img} do
    assert Disk.size(img) == nil
    assert Disk.gb(nil) == "-"
    assert :ok = Disk.create_sparse(img, 64 * @gb)
    assert Disk.gb(Disk.size(img)) == "64G"
  end
end
