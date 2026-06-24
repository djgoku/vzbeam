defmodule VzBeam.Commands.NewTest do
  use ExUnit.Case, async: false
  alias VzBeam.Commands.New

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    File.mkdir_p!(Path.join(home, "base"))
    File.write!(Path.join([home, "base", "config.json"]),
      Jason.encode!(%{"name" => "base", "base" => nil, "macAddress" => "5e:00",
                      "machineIdentifier" => "OLD", "hardwareModel" => "HW",
                      "cpuCount" => 4, "memoryBytes" => 8_589_934_592,
                      "image" => %{"version" => "26.5.1", "build" => "25F80"}}))
    File.write!(Path.join([home, "base", "disk.img"]), "DISK")
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    {:ok, home: home}
  end

  defp deps do
    %{
      reid: fn -> {:ok, %{machine_identifier: "NEW", mac_address: "5e:ff"}} end,
      ensure: fn _ -> {:ok, :fetched, %{"version" => "26.5.1", "build" => "25F80", "file" => "25F80.ipsw"}} end,
      restore: fn opts -> File.touch!(opts.aux);
        {:ok, %{machine_identifier: "RID", hardware_model: "HW2", mac_address: "5e:ab",
                version: "26.5.1", build: "25F80"}} end
    }
  end

  test "clone copies the bundle and re-identifies it", %{home: home} do
    assert {:ok, _} = New.run(["dev", "base"], deps())
    m = Jason.decode!(File.read!(Path.join([home, "dev", "config.json"])))
    assert m["base"] == "base" and m["machineIdentifier"] == "NEW" and m["macAddress"] == "5e:ff"
    assert m["cpuCount"] == 4                      # inherited
    assert File.read!(Path.join([home, "dev", "disk.img"])) == "DISK"  # cloned
    refute File.exists?(Path.join(home, "dev.pending"))
  end

  test "clone refuses a running base", %{home: _home} do
    :ok = VzBeam.Pidfile.write("base", System.pid())
    assert {:error, 1, msg} = New.run(["dev", "base"], deps())
    assert IO.iodata_to_binary(msg) =~ "running"
  end

  test "clone refuses a reserved name" do
    assert {:error, 1, msg} = New.run(["cache", "base"], deps())
    assert IO.iodata_to_binary(msg) =~ "reserved"
  end

  test "restore creates a fresh base with disk.img + aux.img", %{home: home} do
    assert {:ok, _} = New.run(["fresh", "--image", "latest"], deps())
    assert File.regular?(Path.join([home, "fresh", "disk.img"]))
    assert File.regular?(Path.join([home, "fresh", "aux.img"]))
    m = Jason.decode!(File.read!(Path.join([home, "fresh", "config.json"])))
    assert m["base"] == nil and m["machineIdentifier"] == "RID"
  end

  test "--image is mutually exclusive with a base" do
    assert {:error, 2, _} = New.run(["dev", "base", "--image", "latest"], deps())
  end

  test "clone clears a stale .pending and does not nest", %{home: home} do
    File.mkdir_p!(Path.join(home, "dev.pending"))
    File.write!(Path.join([home, "dev.pending", "junk"]), "stale")
    assert {:ok, _} = New.run(["dev", "base"], deps())
    refute File.exists?(Path.join([home, "dev", "junk"]))      # stale junk gone
    refute File.exists?(Path.join([home, "dev", "base"]))      # not nested
    assert File.exists?(Path.join([home, "dev", "config.json"]))
  end

  test "rejects an unknown option" do
    assert {:error, 2, _} = New.run(["dev", "base", "--bogus", "x"], deps())
  end
end
