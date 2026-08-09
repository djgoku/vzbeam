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
      restore: fn opts, _report -> File.touch!(opts.aux);
        {:ok, %{machine_identifier: "RID", hardware_model: "HW2", mac_address: "5e:ab",
                version: "26.5.1", build: "25F80"}} end,
      progress: fn _io -> :ok end
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

  test "restore announces a cache hit and reports install progress", %{home: _home} do
    me = self()

    deps = %{
      deps()
      | ensure: fn _ -> {:ok, :cached, %{"version" => "26.5.1", "build" => "25F80", "file" => "25F80.ipsw"}} end,
        restore: fn opts, report ->
          File.touch!(opts.aux)
          report.({:event, "progress", %{"fraction" => 0.5}})
          report.({:event, "restored", %{}})
          {:ok, %{machine_identifier: "RID", hardware_model: "HW2", mac_address: "5e:ab",
                  version: "26.5.1", build: "25F80"}}
        end,
        progress: fn io -> send(me, {:progress, IO.iodata_to_binary(io)}) end
    }

    assert {:ok, _} = New.run(["fresh", "--image", "https://h/x.ipsw"], deps)
    assert_received {:progress, "using cached image 26.5.1 (25F80)\n"}
    assert_received {:progress, "\rrestoring... 50%"}
    assert_received {:progress, "\rrestoring... 100%\n"}
  end

  test "restore announces a fresh fetch (not a cache hit)", %{home: _home} do
    me = self()
    deps = %{deps() | progress: fn io -> send(me, {:progress, IO.iodata_to_binary(io)}) end}
    assert {:ok, _} = New.run(["fresh", "--image", "https://h/x.ipsw"], deps)
    assert_received {:progress, "fetched 26.5.1 (25F80)\n"}
  end

  test "clone clears a stale .pending and does not nest", %{home: home} do
    File.mkdir_p!(Path.join(home, "dev.pending"))
    File.write!(Path.join([home, "dev.pending", "junk"]), "stale")
    assert {:ok, _} = New.run(["dev", "base"], deps())
    refute File.exists?(Path.join([home, "dev", "junk"]))      # stale junk gone
    refute File.exists?(Path.join([home, "dev", "base"]))      # not nested
    assert File.exists?(Path.join([home, "dev", "config.json"]))
  end

  @gb 1024 * 1024 * 1024

  defp sparse!(path, size) do
    {:ok, :ok} = File.open(path, [:write, :raw], fn fd -> :file.pwrite(fd, size - 1, <<0>>) end)
  end

  test "clone honors --disk-gb by growing the cloned disk", %{home: home} do
    assert {:ok, msg} = New.run(["dev", "base", "--disk-gb", "2"], deps())
    assert IO.iodata_to_binary(msg) =~ "disk=2G"
    assert IO.iodata_to_binary(msg) =~ "recoveryOS"  # inherits the base layout
    assert File.stat!(Path.join([home, "dev", "disk.img"])).size == 2 * @gb
    assert File.stat!(Path.join([home, "base", "disk.img"])).size == 4  # base untouched
  end

  test "clone refuses a --disk-gb smaller than the base disk", %{home: home} do
    sparse!(Path.join([home, "base", "disk.img"]), 2 * @gb)
    assert {:error, 1, msg} = New.run(["dev", "base", "--disk-gb", "1"], deps())
    assert IO.iodata_to_binary(msg) =~ ">= the base disk (2G)"
    refute File.exists?(Path.join(home, "dev"))
  end

  test "clone honors --cpu and --mem-gb overrides", %{home: home} do
    assert {:ok, msg} = New.run(["dev", "base", "--cpu", "8", "--mem-gb", "16"], deps())
    assert IO.iodata_to_binary(msg) =~ "cpu=8 mem=16G"
    m = Jason.decode!(File.read!(Path.join([home, "dev", "config.json"])))
    assert m["cpuCount"] == 8 and m["memoryBytes"] == 16 * @gb
  end

  test "clone rejects non-positive cpu and memory overrides before creating a bundle", %{
    home: home
  } do
    for args <- [
          ["--cpu", "0"],
          ["--cpu", "-1"],
          ["--mem-gb", "0"],
          ["--mem-gb", "-1"],
          ["--disk-gb", "0"],
          ["--disk-gb", "-1"]
        ] do
      assert {:error, 2, msg} = New.run(["dev", "base" | args], deps())
      assert IO.iodata_to_binary(msg) =~ "must be >= 1"
      refute File.exists?(Path.join(home, "dev"))
      refute File.exists?(Path.join(home, "dev.pending"))
    end
  end

  test "restore rejects non-positive sizing overrides before creating a bundle", %{home: home} do
    for args <- [["--cpu", "0"], ["--mem-gb", "0"], ["--disk-gb", "0"]] do
      assert {:error, 2, msg} = New.run(["fresh", "--image", "latest" | args], deps())
      assert IO.iodata_to_binary(msg) =~ "must be >= 1"
      refute File.exists?(Path.join(home, "fresh"))
      refute File.exists?(Path.join(home, "fresh.pending"))
    end
  end

  test "rejects an unknown option" do
    assert {:error, 2, _} = New.run(["dev", "base", "--bogus", "x"], deps())
  end
end
