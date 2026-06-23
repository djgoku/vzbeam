defmodule VzBeam.ManifestTest do
  use ExUnit.Case, async: false

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "base"))
    System.put_env("VZBEAM_HOME", home)
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    {:ok, home: home}
  end

  test "write then read round-trips and adds schemaVersion" do
    :ok = VzBeam.Manifest.write("base", %{"name" => "base", "macAddress" => "5e:aa"})
    assert {:ok, m} = VzBeam.Manifest.read("base")
    assert m["name"] == "base"
    assert m["schemaVersion"] == 1
  end

  test "read of a missing manifest errors" do
    assert {:error, _} = VzBeam.Manifest.read("ghost")
  end

  test "unknown keys survive a read-modify-write" do
    :ok = VzBeam.Manifest.write("base", %{"name" => "base", "future" => "keepme"})
    {:ok, m} = VzBeam.Manifest.read("base")
    :ok = VzBeam.Manifest.write("base", Map.put(m, "cpuCount", 4))
    {:ok, m2} = VzBeam.Manifest.read("base")
    assert m2["future"] == "keepme" and m2["cpuCount"] == 4
  end
end
