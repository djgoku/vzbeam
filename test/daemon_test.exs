defmodule VzBeam.DaemonTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "vzbeam-daemon-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "returns {:error, ...} when the spawn shell fails (injected runner)" do
    runner = fn "sh", ["-c", _cmd], _ -> {"boom", 1} end
    assert {:error, {:spawn_failed, 1, "boom"}} =
             VzBeam.Daemon.spawn_detached(["/bin/true"], "/tmp/x.log", runner)
  end

  test "spawns a detached child, redirects stdio to the log, returns a live reparented pid", %{dir: dir} do
    log = Path.join([dir, "sub dir", "run.log"])  # spaces in the path exercise quoting
    File.mkdir_p!(Path.dirname(log))

    {:ok, pid} =
      VzBeam.Daemon.spawn_detached(["/bin/sh", "-c", "echo hello; sleep 30"], log)

    on_exit(fn -> System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true) end)

    assert is_integer(pid)
    Process.sleep(300)
    assert File.read!(log) =~ "hello"
    assert {_, 0} = System.cmd("ps", ["-p", Integer.to_string(pid)], stderr_to_stdout: true)
    {ppid, 0} = System.cmd("ps", ["-o", "ppid=", "-p", Integer.to_string(pid)])
    assert String.trim(ppid) == "1"  # reparented to launchd => survives BEAM exit
  end
end
