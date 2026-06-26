defmodule VzBeam.Commands.SetTest do
  use ExUnit.Case, async: false
  alias VzBeam.Commands.Set

  @gb 1024 * 1024 * 1024

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-set-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    File.mkdir_p!(Path.join(home, "dev"))
    File.write!(Path.join([home, "dev", "config.json"]),
      Jason.encode!(%{"name" => "dev", "cpuCount" => 4, "memoryBytes" => 8 * @gb,
                      "macAddress" => "5e:aa", "machineIdentifier" => "MID"}))
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    {:ok, home: home}
  end

  defp manifest(home), do: Jason.decode!(File.read!(Path.join([home, "dev", "config.json"])))

  test "sets cpu and mem, preserving other keys", %{home: home} do
    assert {:ok, msg} = Set.run(["dev", "--cpu", "8", "--mem-gb", "16"])
    assert IO.iodata_to_binary(msg) =~ "cpu=8 mem=16G"
    m = manifest(home)
    assert m["cpuCount"] == 8 and m["memoryBytes"] == 16 * @gb and m["macAddress"] == "5e:aa"
  end

  test "cpu-only leaves mem unchanged and still prints both", %{home: home} do
    assert {:ok, msg} = Set.run(["dev", "--cpu", "2"])
    assert IO.iodata_to_binary(msg) =~ "cpu=2 mem=8G"
    assert manifest(home)["memoryBytes"] == 8 * @gb
  end

  test "refuses a running VM" do
    :ok = VzBeam.Pidfile.write("dev", System.pid())
    assert {:error, 1, msg} = Set.run(["dev", "--cpu", "2"])
    assert IO.iodata_to_binary(msg) =~ "running"
  end

  test "errors on a missing bundle" do
    assert {:error, 1, msg} = Set.run(["ghost", "--cpu", "2"])
    assert IO.iodata_to_binary(msg) =~ "no such bundle"
  end

  test "usage (exit 2) on no-flags, extra positional, bad-typed, unknown flag, sub-1 values" do
    assert {:error, 2, _} = Set.run(["dev"])
    assert {:error, 2, _} = Set.run(["dev", "extra", "--cpu", "2"])
    assert {:error, 2, _} = Set.run(["dev", "--cpu", "nope"])
    assert {:error, 2, _} = Set.run(["dev", "--bogus"])
    assert {:error, 2, _} = Set.run(["dev", "--cpu", "0"])
    assert {:error, 2, _} = Set.run(["dev", "--mem-gb", "0"])
  end

  test "mem-only leaves cpu unchanged and still prints both", %{home: home} do
    assert {:ok, msg} = Set.run(["dev", "--mem-gb", "16"])
    assert IO.iodata_to_binary(msg) =~ "cpu=4 mem=16G"
    assert manifest(home)["cpuCount"] == 4
  end

  test "surfaces a write failure as exit 1", %{home: home} do
    dir = Path.join(home, "dev")
    File.chmod!(dir, 0o500)                     # no write -> the atomic write fails
    on_exit(fn -> File.chmod(dir, 0o700) end)   # restore so setup's rm_rf can clean up
    assert {:error, 1, msg} = Set.run(["dev", "--cpu", "2"])
    assert IO.iodata_to_binary(msg) =~ "set failed"
  end
end
