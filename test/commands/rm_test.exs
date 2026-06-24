defmodule VzBeam.Commands.RmTest do
  use ExUnit.Case, async: false

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    File.mkdir_p!(Path.join(home, "dev"))
    File.write!(Path.join([home, "dev", "config.json"]), "{}")
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    {:ok, home: home}
  end

  test "removes a stopped bundle", %{home: home} do
    assert {:ok, _} = VzBeam.Commands.Rm.run(["dev"])
    refute File.exists?(Path.join(home, "dev"))
  end

  test "refuses a running bundle" do
    :ok = VzBeam.Pidfile.write("dev", System.pid())
    assert {:error, 1, msg} = VzBeam.Commands.Rm.run(["dev"])
    assert IO.iodata_to_binary(msg) =~ "running"
  end

  test "errors on a missing bundle" do
    assert {:error, 1, msg} = VzBeam.Commands.Rm.run(["ghost"])
    assert IO.iodata_to_binary(msg) =~ "no such bundle"
  end

  test "usage error with no name" do
    assert {:error, 2, _} = VzBeam.Commands.Rm.run([])
  end
end
