defmodule VzBeam.Commands.RunTest do
  use ExUnit.Case, async: false
  alias VzBeam.Commands.Run

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-run-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    System.put_env("VZBEAM_VZ", Path.expand("../support/fake_vz", __DIR__))
    File.chmod!(Path.expand("../support/fake_vz", __DIR__), 0o755)
    make_bundle("dev")
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); System.delete_env("VZBEAM_VZ"); File.rm_rf!(home) end)
    {:ok, home: home}
  end

  defp make_bundle(name) do
    dir = Path.join(System.get_env("VZBEAM_HOME"), name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "config.json"),
      Jason.encode!(%{"name" => name, "macAddress" => "5e:aa:bb:cc:dd:ee",
                      "machineIdentifier" => "MID", "hardwareModel" => "HW",
                      "cpuCount" => 2, "memoryBytes" => 2_147_483_648}))
  end

  # with_lock that just runs the fun (no real locking); spawn returns a chosen result.
  defp deps(spawn_fn), do: %{with_lock: fn fun -> {:ok, fun.()} end, spawn: spawn_fn}

  test "usage error without a name" do
    assert {:error, 2, _} = Run.run([], deps(fn _, _ -> {:ok, 1} end))
  end

  test "refuses a missing bundle" do
    assert {:error, 1, msg} = Run.run(["ghost"], deps(fn _, _ -> {:ok, 1} end))
    assert IO.iodata_to_binary(msg) =~ "no such bundle"
  end

  test "refuses at the 2-VM cap (real count_running over two live pidfiles)" do
    for n <- ["a", "b"] do
      make_bundle(n)
      :ok = VzBeam.Pidfile.write(n, System.pid())  # System.pid() is alive => counts as running
    end

    assert {:error, 1, msg} = Run.run(["dev"], deps(fn _, _ -> flunk("must not spawn at cap") end))
    assert IO.iodata_to_binary(msg) =~ "capacity"
  end

  test "spawn forked but vz exited fast -> :process_not_found path -> typed error, no stale vm.pid" do
    # spawn returns a pid that is already dead, and we pre-seed run.log with an error event.
    File.write!(Path.join([System.get_env("VZBEAM_HOME"), "dev", "run.log"]),
      ~s({"type":"error","domain":"VZErrorDomain","code":6,"message":"max VMs"}\n))

    assert {:error, 1, msg} = Run.run(["dev"], deps(fn _argv, _log -> {:ok, 999_999} end))
    assert IO.iodata_to_binary(msg) =~ "capacity"
    refute File.exists?(VzBeam.Pidfile.path("dev"))
  end

  test "a non-cap VZError surfaces as a generic run-failed message" do
    File.write!(Path.join([System.get_env("VZBEAM_HOME"), "dev", "run.log"]),
      ~s({"type":"error","domain":"VZErrorDomain","code":7,"message":"boom"}\n))
    assert {:error, 1, msg} = Run.run(["dev"], deps(fn _argv, _log -> {:ok, 999_999} end))
    assert IO.iodata_to_binary(msg) =~ "VZError 7"
    refute File.exists?(VzBeam.Pidfile.path("dev"))
  end

  test "happy path: started + live pid -> success, vm.pid written" do
    # spawn a real, live child and pre-seed run.log with a 'started' line.
    {out, 0} = System.cmd("sh", ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"])
    pid = out |> String.trim() |> String.to_integer()
    on_exit(fn -> System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true) end)
    File.write!(Path.join([System.get_env("VZBEAM_HOME"), "dev", "run.log"]),
      ~s({"type":"started","pid":#{pid}}\n))

    assert {:ok, msg} = Run.run(["dev"], deps(fn _argv, _log -> {:ok, pid} end))
    assert IO.iodata_to_binary(msg) =~ "started dev"
    assert {:ok, %{"pid" => ^pid}} = VzBeam.Pidfile.read("dev")
  end

  test "await_started: started+alive -> ok; started+dead -> exited_early; error -> vz; timeout" do
    log = Path.join([System.get_env("VZBEAM_HOME"), "dev", "hs.log"])
    File.mkdir_p!(Path.dirname(log))

    me = System.pid() |> String.to_integer()  # the BEAM is always alive
    File.write!(log, ~s({"type":"started","pid":#{me}}\n))
    assert {:ok, ^me} = Run.await_started(log, me, 1_000)

    File.write!(log, ~s({"type":"started","pid":999999}\n))
    assert {:error, :exited_early} = Run.await_started(log, 999_999, 1_000)

    File.write!(log, ~s({"type":"error","domain":"D","code":6,"message":"m"}\n))
    assert {:error, {:vz, "D", 6, "m"}} = Run.await_started(log, me, 1_000)

    File.write!(log, "")  # no started, BEAM alive -> times out
    assert {:error, :timeout} = Run.await_started(log, me, 30)
  end

  test "argv carries identity + explicit disk/aux and drops --bundle" do
    {out, 0} = System.cmd("sh", ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"])
    pid = out |> String.trim() |> String.to_integer()
    on_exit(fn -> System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true) end)
    File.write!(Path.join([System.get_env("VZBEAM_HOME"), "dev", "run.log"]),
      ~s({"type":"started","pid":#{pid}}\n))

    parent = self()
    spawn = fn argv, _log -> send(parent, {:argv, argv}); {:ok, pid} end
    assert {:ok, _} = Run.run(["dev"], deps(spawn))

    assert_received {:argv, argv}
    home = System.get_env("VZBEAM_HOME")
    refute "--bundle" in argv
    assert arg_after(argv, "--machine-id") == "MID"
    assert arg_after(argv, "--hardware-model") == "HW"
    assert arg_after(argv, "--disk") == Path.join([home, "dev", "disk.img"])
    assert arg_after(argv, "--aux") == Path.join([home, "dev", "aux.img"])
    assert arg_after(argv, "--mac") == "5e:aa:bb:cc:dd:ee"
    assert "--headless" in argv
    assert arg_after(argv, "--resolution") == "1920x1200"
  end

  defp arg_after(argv, flag) do
    case Enum.find_index(argv, &(&1 == flag)) do
      nil -> nil
      i -> Enum.at(argv, i + 1)
    end
  end
end
