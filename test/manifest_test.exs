defmodule VzBeam.ManifestTest do
  use ExUnit.Case, async: false

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "base"))
    System.put_env("VZBEAM_HOME", home)
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    {:ok, home: home}
  end

  test "read returns the decoded config.json" do
    File.write!(Path.join([System.get_env("VZBEAM_HOME"), "base", "config.json"]),
      Jason.encode!(%{"name" => "base", "macAddress" => "5e:aa"}))
    assert {:ok, %{"name" => "base", "macAddress" => "5e:aa"}} = VzBeam.Manifest.read("base")
  end

  test "read of a missing manifest errors" do
    assert {:error, _} = VzBeam.Manifest.read("ghost")
  end

  test "read_or returns the map or the caller's error" do
    File.write!(Path.join([System.get_env("VZBEAM_HOME"), "base", "config.json"]),
      Jason.encode!(%{"name" => "base"}))
    assert {:ok, %{"name" => "base"}} = VzBeam.Manifest.read_or("base", :nope)
    assert {:error, :nope} = VzBeam.Manifest.read_or("ghost", :nope)
  end

  test "write_to stamps schemaVersion and round-trips via read" do
    :ok = VzBeam.Manifest.write_to(VzBeam.Manifest.path("base"), %{"name" => "base", "macAddress" => "5e:aa"})
    assert {:ok, %{"name" => "base", "macAddress" => "5e:aa", "schemaVersion" => 1}} =
             VzBeam.Manifest.read("base")
  end
end
