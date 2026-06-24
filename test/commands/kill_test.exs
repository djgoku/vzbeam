defmodule VzBeam.Commands.KillTest do
  use ExUnit.Case, async: false
  alias VzBeam.Commands.Kill

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-kill-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    File.mkdir_p!(Path.join(home, "dev"))
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    :ok
  end

  test "SIGTERM stops a real running child and cleans vm.pid" do
    {out, 0} = System.cmd("sh", ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"])
    pid = out |> String.trim() |> String.to_integer()
    :ok = VzBeam.Pidfile.write("dev", pid)

    assert {:ok, msg} = Kill.run(["dev"], VzBeam.Commands.Kill.default_deps())
    assert IO.iodata_to_binary(msg) =~ "killed dev"
    refute VzBeam.Pidfile.running?("dev")
  end

  test "escalates to SIGKILL on timeout (injected signal records the escalation)" do
    :ok = VzBeam.Pidfile.write("dev", System.pid())  # alive; our fake signal won't kill the BEAM
    parent = self()
    deps = %{signal: fn sig, _pid -> send(parent, {:sig, sig}); {"", 0} end, reap_ms: 0}

    assert {:ok, msg} = Kill.run(["dev"], deps)
    assert IO.iodata_to_binary(msg) =~ "SIGKILL"
    assert_received {:sig, "-TERM"}
    assert_received {:sig, "-KILL"}
    File.rm(VzBeam.Pidfile.path("dev"))
  end

  test "cleans a stale vm.pid and reports not running" do
    :ok = File.write!(VzBeam.Pidfile.path("dev"),
      Jason.encode!(%{"pid" => 999_999, "startedAt" => "x", "bundle" => "dev"}))
    assert {:ok, msg} = Kill.run(["dev"], VzBeam.Commands.Kill.default_deps())
    assert IO.iodata_to_binary(msg) =~ "not running"
    refute File.exists?(VzBeam.Pidfile.path("dev"))
  end

  test "errors on a VM with no vm.pid" do
    assert {:error, 1, msg} = Kill.run(["dev"], VzBeam.Commands.Kill.default_deps())
    assert IO.iodata_to_binary(msg) =~ "no such running VM"
  end
end
