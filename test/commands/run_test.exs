defmodule VzBeam.Commands.RunTest do
  use ExUnit.Case, async: false
  alias VzBeam.{Commands.Run, IsoCache}

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-run-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    System.put_env("VZBEAM_VZ", Path.expand("../support/fake_vz", __DIR__))
    File.chmod!(Path.expand("../support/fake_vz", __DIR__), 0o755)
    make_bundle("dev")
    make_openbsd_bundle("obsd")

    on_exit(fn ->
      System.delete_env("VZBEAM_HOME")
      System.delete_env("VZBEAM_VZ")
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  defp make_bundle(name) do
    dir = Path.join(System.get_env("VZBEAM_HOME"), name)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "config.json"),
      Jason.encode!(%{
        "name" => name,
        "macAddress" => "5e:aa:bb:cc:dd:ee",
        "machineIdentifier" => "MID",
        "hardwareModel" => "HW",
        "cpuCount" => 2,
        "memoryBytes" => 2_147_483_648
      })
    )
  end

  defp make_openbsd_bundle(name) do
    home = System.get_env("VZBEAM_HOME")
    dir = Path.join(home, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "disk.img"), "disk")
    File.write!(Path.join(dir, "nvram.bin"), "nvram")

    bytes = "cached-openbsd-iso"
    digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    file = digest <> ".iso"
    File.mkdir_p!(IsoCache.dir())
    File.write!(Path.join(IsoCache.dir(), file), bytes)

    File.write!(
      Path.join(dir, "config.json"),
      Jason.encode!(%{
        "schemaVersion" => 2,
        "guestOS" => "openbsd",
        "name" => name,
        "base" => nil,
        "image" => %{
          "kind" => "iso",
          "file" => file,
          "sha256" => digest,
          "version" => "7.9"
        },
        "macAddress" => "5e:79:00:00:00:01",
        "machineIdentifier" => "OPENBSD-ID",
        "sshUser" => "admin",
        "cpuCount" => 2,
        "memoryBytes" => 2_147_483_648
      })
    )
  end

  defp live_pid_with_started_log(name) do
    {out, 0} = System.cmd("sh", ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"])
    pid = out |> String.trim() |> String.to_integer()

    on_exit(fn ->
      System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
    end)

    File.write!(
      Path.join([System.get_env("VZBEAM_HOME"), name, "run.log"]),
      ~s({"type":"started","pid":#{pid}}\n)
    )

    pid
  end

  defp capture_argv(args, name) do
    pid = live_pid_with_started_log(name)
    parent = self()

    assert {:ok, _} =
             Run.run(
               args,
               deps(fn argv, _log ->
                 send(parent, {:argv, argv})
                 {:ok, pid}
               end)
             )

    assert_receive {:argv, argv}
    File.rm(VzBeam.Pidfile.path(name))
    argv
  end

  # with_lock that just runs the fun (no real locking); spawn returns a chosen result.
  defp deps(spawn_fn), do: %{with_lock: fn fun -> {:ok, fun.()} end, spawn: spawn_fn}

  test "usage error without a name" do
    assert {:error, 2, _} = Run.run([], deps(fn _, _ -> {:ok, 1} end))
  end

  test "rejects an unknown option" do
    assert {:error, 2, msg} = Run.run(["dev", "--bogus"], deps(fn _, _ -> {:ok, 999_999} end))
    assert IO.iodata_to_binary(msg) =~ "unknown option"
  end

  test "rejects --gui and --headless together" do
    assert {:error, 2, msg} =
             Run.run(["dev", "--gui", "--headless"], deps(fn _, _ -> {:ok, 999_999} end))

    assert IO.iodata_to_binary(msg) =~ "mutually exclusive"
  end

  test "refuses a missing bundle" do
    assert {:error, 1, msg} = Run.run(["ghost"], deps(fn _, _ -> {:ok, 1} end))
    assert IO.iodata_to_binary(msg) =~ "no such bundle"
  end

  test "protocol mismatch tells the user to rebuild the sidecar before spawn", %{home: home} do
    stale = Path.join(home, "stale-vz")

    File.write!(
      stale,
      "#!/bin/sh\necho '{\"type\":\"version\",\"protocol\":1}'\n"
    )

    File.chmod!(stale, 0o755)
    System.put_env("VZBEAM_VZ", stale)

    assert {:error, 1, message} =
             Run.run(["dev"], deps(fn _, _ -> flunk("stale sidecar must not spawn") end))

    text = IO.iodata_to_binary(message)
    assert text =~ "protocol 1"
    assert text =~ "mix vz.build"
  end

  test "refuses at the 2-VM cap (real count_running over two live pidfiles)" do
    for n <- ["a", "b"] do
      make_bundle(n)
      # System.pid() is alive => counts as running
      :ok = VzBeam.Pidfile.write(n, System.pid())
    end

    assert {:error, 1, msg} =
             Run.run(["dev"], deps(fn _, _ -> flunk("must not spawn at cap") end))

    assert IO.iodata_to_binary(msg) =~ "capacity"
  end

  test "spawn forked but vz exited fast -> :process_not_found path -> typed error, no stale vm.pid" do
    # spawn returns a pid that is already dead, and we pre-seed run.log with an error event.
    File.write!(
      Path.join([System.get_env("VZBEAM_HOME"), "dev", "run.log"]),
      ~s({"type":"error","domain":"VZErrorDomain","code":6,"message":"max VMs"}\n)
    )

    assert {:error, 1, msg} = Run.run(["dev"], deps(fn _argv, _log -> {:ok, 999_999} end))
    assert IO.iodata_to_binary(msg) =~ "capacity"
    refute File.exists?(VzBeam.Pidfile.path("dev"))
  end

  test "a non-cap VZError surfaces as a generic run-failed message" do
    File.write!(
      Path.join([System.get_env("VZBEAM_HOME"), "dev", "run.log"]),
      ~s({"type":"error","domain":"VZErrorDomain","code":7,"message":"boom"}\n)
    )

    assert {:error, 1, msg} = Run.run(["dev"], deps(fn _argv, _log -> {:ok, 999_999} end))
    assert IO.iodata_to_binary(msg) =~ "VZError 7"
    refute File.exists?(VzBeam.Pidfile.path("dev"))
  end

  test "happy path: started + live pid -> success, vm.pid written" do
    # spawn a real, live child and pre-seed run.log with a 'started' line.
    {out, 0} = System.cmd("sh", ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"])
    pid = out |> String.trim() |> String.to_integer()

    on_exit(fn ->
      System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
    end)

    File.write!(
      Path.join([System.get_env("VZBEAM_HOME"), "dev", "run.log"]),
      ~s({"type":"started","pid":#{pid}}\n)
    )

    assert {:ok, msg} = Run.run(["dev"], deps(fn _argv, _log -> {:ok, pid} end))
    assert IO.iodata_to_binary(msg) =~ "started dev"
    refute IO.iodata_to_binary(msg) =~ "closing the window"
    assert {:ok, %{"pid" => ^pid}} = VzBeam.Pidfile.read("dev")
  end

  test "--gui start explains that closing the window leaves the VM running" do
    {out, 0} = System.cmd("sh", ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"])
    pid = out |> String.trim() |> String.to_integer()

    on_exit(fn ->
      System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
    end)

    File.write!(
      Path.join([System.get_env("VZBEAM_HOME"), "dev", "run.log"]),
      ~s({"type":"started","pid":#{pid}}\n)
    )

    assert {:ok, msg} = Run.run(["dev", "--gui"], deps(fn _argv, _log -> {:ok, pid} end))
    msg = IO.iodata_to_binary(msg)
    assert msg =~ "closing the window leaves dev running"
    assert msg =~ "`vzbeam stop dev`"
  end

  test "await_started: started+alive -> ok; started+dead -> exited_early; error -> vz; timeout" do
    log = Path.join([System.get_env("VZBEAM_HOME"), "dev", "hs.log"])
    File.mkdir_p!(Path.dirname(log))

    # the BEAM is always alive
    me = System.pid() |> String.to_integer()
    File.write!(log, ~s({"type":"started","pid":#{me}}\n))
    assert {:ok, ^me} = Run.await_started(log, me, 1_000)

    File.write!(log, ~s({"type":"started","pid":999999}\n))
    assert {:error, :exited_early} = Run.await_started(log, 999_999, 1_000)

    File.write!(log, ~s({"type":"error","domain":"D","code":6,"message":"m"}\n))
    assert {:error, {:vz, "D", 6, "m"}} = Run.await_started(log, me, 1_000)

    # no started, BEAM alive -> times out
    File.write!(log, "")
    assert {:error, :timeout} = Run.await_started(log, me, 30)
  end

  test "argv carries identity + explicit disk/aux and drops --bundle" do
    {out, 0} = System.cmd("sh", ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"])
    pid = out |> String.trim() |> String.to_integer()

    on_exit(fn ->
      System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
    end)

    File.write!(
      Path.join([System.get_env("VZBEAM_HOME"), "dev", "run.log"]),
      ~s({"type":"started","pid":#{pid}}\n)
    )

    parent = self()

    spawn = fn argv, _log ->
      send(parent, {:argv, argv})
      {:ok, pid}
    end

    assert {:ok, _} = Run.run(["dev"], deps(spawn))

    assert_received {:argv, argv}
    home = System.get_env("VZBEAM_HOME")
    refute "--bundle" in argv
    assert arg_after(argv, "--guest") == "macos"
    assert arg_after(argv, "--machine-id") == "MID"
    assert arg_after(argv, "--hardware-model") == "HW"
    assert arg_after(argv, "--disk") == Path.join([home, "dev", "disk.img"])
    assert arg_after(argv, "--aux") == Path.join([home, "dev", "aux.img"])
    assert arg_after(argv, "--mac") == "5e:aa:bb:cc:dd:ee"
    assert "--headless" in argv
    assert arg_after(argv, "--resolution") == "1920x1200"
  end

  test "OpenBSD argv uses generic identity, disk, and NVRAM without Mac fields", %{home: home} do
    argv = capture_argv(["obsd"], "obsd")
    assert arg_after(argv, "--guest") == "openbsd"
    assert arg_after(argv, "--machine-id") == "OPENBSD-ID"
    assert arg_after(argv, "--nvram") == Path.join([home, "obsd", "nvram.bin"])
    assert arg_after(argv, "--disk") == Path.join([home, "obsd", "disk.img"])
    refute "--hardware-model" in argv
    refute "--aux" in argv
    refute "--iso" in argv
  end

  # The sidecar puts the bundle name in the window title, so several open VMs can be told apart.
  test "passes the bundle name to the sidecar for the window title" do
    assert arg_after(capture_argv(["obsd", "--gui"], "obsd"), "--name") == "obsd"
    assert arg_after(capture_argv(["obsd", "--iso"], "obsd"), "--name") == "obsd"
  end

  test "bare recovery uses the cached ISO and forces GUI" do
    manifest = Jason.decode!(File.read!(VzBeam.Manifest.path("obsd")))
    expected = Path.join(IsoCache.dir(), manifest["image"]["file"])
    argv = capture_argv(["obsd", "--iso"], "obsd")
    assert arg_after(argv, "--iso") == expected
    assert "--gui" in argv
    refute "--headless" in argv
  end

  test "one-shot recovery supports name-first and path-first without mutating the manifest", %{
    home: home
  } do
    rescue_iso = Path.join(home, "rescue.iso")
    File.write!(rescue_iso, "one-shot")
    before = File.read!(VzBeam.Manifest.path("obsd"))

    for args <- [
          ["obsd", "--iso", rescue_iso],
          ["--iso", rescue_iso, "obsd"],
          ["--iso=#{rescue_iso}", "obsd"]
        ] do
      argv = capture_argv(args, "obsd")
      assert arg_after(argv, "--iso") == rescue_iso
      assert "--gui" in argv
      assert File.read!(VzBeam.Manifest.path("obsd")) == before
    end
  end

  test "recovery and share policy failures never spawn", %{home: home} do
    never_spawn = deps(fn _argv, _log -> flunk("invalid recovery request spawned sidecar") end)
    manifest_path = VzBeam.Manifest.path("obsd")
    manifest_bytes = File.read!(manifest_path)
    manifest = Jason.decode!(manifest_bytes)
    cached = Path.join(IsoCache.dir(), manifest["image"]["file"])
    File.rm!(cached)

    assert {:error, 1, missing} = Run.run(["obsd", "--iso"], never_spawn)
    missing_text = IO.iodata_to_binary(missing)
    assert missing_text =~ "cached ISO"
    assert missing_text =~ manifest["image"]["sha256"]
    assert missing_text =~ cached
    assert File.read!(manifest_path) == manifest_bytes

    empty = Path.join(home, "empty.iso")
    File.write!(empty, "")

    for path <- [Path.join(home, "missing.iso"), empty] do
      assert {:error, 1, message} = Run.run(["obsd", "--iso", path], never_spawn)
      text = IO.iodata_to_binary(message)
      assert text =~ "ISO"
      assert text =~ path
      assert File.read!(manifest_path) == manifest_bytes
    end

    assert {:error, 2, share} =
             Run.run(["obsd", "--share", "src=/tmp"], never_spawn)

    assert IO.iodata_to_binary(share) =~ "not supported for OpenBSD"

    assert {:error, 2, mac_iso} = Run.run(["dev", "--iso"], never_spawn)
    assert IO.iodata_to_binary(mac_iso) =~ "only supported for OpenBSD"
  end

  test "corrupt cached media and missing NVRAM fail before spawn" do
    never_spawn = deps(fn _argv, _log -> flunk("invalid bundle spawned sidecar") end)
    manifest = Jason.decode!(File.read!(VzBeam.Manifest.path("obsd")))
    File.write!(Path.join(IsoCache.dir(), manifest["image"]["file"]), "corrupt")

    assert {:error, 1, corrupt} = Run.run(["obsd", "--iso"], never_spawn)
    assert IO.iodata_to_binary(corrupt) =~ "cached ISO"

    File.rm!(Path.join([System.get_env("VZBEAM_HOME"), "obsd", "nvram.bin"]))
    assert {:error, 1, nvram} = Run.run(["obsd"], never_spawn)
    assert IO.iodata_to_binary(nvram) =~ "nvram.bin"
  end

  test "optional ISO syntax and mode errors fail before spawn" do
    never_spawn = deps(fn _argv, _log -> flunk("invalid syntax spawned sidecar") end)

    for {args, expected} <- [
          {["obsd", "--iso", "--headless"], "--headless"},
          {["obsd", "--iso", "--iso"], "once"},
          {["obsd", "--iso="], "usage"},
          {["obsd", "--no-iso"], "usage"},
          {["obsd", "--resolution", "wide"], "resolution"}
        ] do
      assert {:error, 2, message} = Run.run(args, never_spawn)
      assert IO.iodata_to_binary(message) =~ expected
    end
  end

  test "malformed and unsupported manifests are described before spawn", %{home: home} do
    never_spawn = deps(fn _argv, _log -> flunk("invalid manifest spawned sidecar") end)

    invalid_dir = Path.join(home, "invalid")
    File.mkdir_p!(invalid_dir)
    File.write!(Path.join(invalid_dir, "config.json"), "not-json")
    assert {:error, 1, invalid} = Run.run(["invalid"], never_spawn)
    assert IO.iodata_to_binary(invalid) =~ "invalid config.json"

    unsupported_dir = Path.join(home, "unsupported")
    File.mkdir_p!(unsupported_dir)

    File.write!(
      Path.join(unsupported_dir, "config.json"),
      Jason.encode!(%{"schemaVersion" => 2, "guestOS" => "linux"})
    )

    assert {:error, 1, unsupported} = Run.run(["unsupported"], never_spawn)
    assert IO.iodata_to_binary(unsupported) =~ "unsupported guest OS linux"
  end

  test "running OpenBSD guests do not consume the two-macOS-VM capacity", %{home: _home} do
    for name <- ["obsd-a", "obsd-b", "obsd-c"] do
      make_openbsd_bundle(name)
      :ok = VzBeam.Pidfile.write(name, System.pid())
    end

    pid = live_pid_with_started_log("dev")
    assert {:ok, _} = Run.run(["dev"], deps(fn _argv, _log -> {:ok, pid} end))
  end

  defp arg_after(argv, flag) do
    case Enum.find_index(argv, &(&1 == flag)) do
      nil -> nil
      i -> Enum.at(argv, i + 1)
    end
  end
end
