defmodule VzBeam.Commands.StopTest do
  use ExUnit.Case, async: false
  alias VzBeam.Commands.Stop

  @mac "5e:aa:bb:cc:dd:ee"

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-stop-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    dir = Path.join(home, "dev")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "config.json"),
      Jason.encode!(%{"name" => "dev", "macAddress" => @mac})
    )

    obsd = Path.join(home, "obsd")
    File.mkdir_p!(obsd)

    File.write!(
      Path.join(obsd, "config.json"),
      Jason.encode!(%{
        "schemaVersion" => 2,
        "guestOS" => "openbsd",
        "name" => "obsd",
        "macAddress" => "5e:79:00:00:00:01",
        "sshUser" => "deploy"
      })
    )

    # running
    :ok = VzBeam.Pidfile.write("dev", System.pid())
    :ok = VzBeam.Pidfile.write("obsd", System.pid())

    on_exit(fn ->
      System.delete_env("VZBEAM_HOME")
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  defp leases do
    "{\n\tname=dev\n\tip_address=192.168.64.7\n\thw_address=1,#{@mac}\n}\n" <>
      "{\n\tname=obsd\n\tip_address=192.168.64.8\n\thw_address=1,5e:79:00:00:00:01\n}\n"
  end

  test "issues a key-based, BatchMode, sudo -n shutdown and reaps on pid disappearance" do
    parent = self()

    ssh = fn args ->
      send(parent, {:ssh, args})
      # simulate guest shutdown -> process gone
      File.rm(VzBeam.Pidfile.path("dev"))
      {"", 0}
    end

    assert {:ok, msg} = Stop.run(["dev"], %{ssh: ssh, leases: fn -> leases() end, reap_ms: 5_000})
    assert IO.iodata_to_binary(msg) =~ "stopped dev"
    assert_received {:ssh, args}
    joined = Enum.join(args, " ")

    assert joined =~ "BatchMode=yes" and joined =~ "sudo -n shutdown -h now" and
             joined =~ "admin@192.168.64.7"

    refute File.exists?(VzBeam.Pidfile.path("dev"))
  end

  test "times out when the VM does not stop" do
    # does nothing; pid stays alive
    ssh = fn _ -> {"", 0} end

    assert {:error, 1, msg} =
             Stop.run(["dev"], %{ssh: ssh, leases: fn -> leases() end, reap_ms: 0})

    assert IO.iodata_to_binary(msg) =~ "kill"
  end

  test "OpenBSD uses the stored user and doas poweroff command" do
    parent = self()

    ssh = fn args ->
      send(parent, {:ssh, args})
      File.rm(VzBeam.Pidfile.path("obsd"))
      {"", 0}
    end

    assert {:ok, message} =
             Stop.run(["obsd"], %{ssh: ssh, leases: fn -> leases() end, reap_ms: 5_000})

    assert IO.iodata_to_binary(message) =~ "stopped obsd"
    assert_received {:ssh, args}
    joined = Enum.join(args, " ")
    assert joined =~ "deploy@192.168.64.8"
    assert joined =~ "doas -n /sbin/shutdown -p now"
  end

  test "reports a clear error (no reap hang) when guest sudo needs a password" do
    ssh = fn _ -> {"sudo: a password is required\n", 1} end
    # reap_ms is large; the auth-failure short-circuit must return immediately, not wait it out.
    assert {:error, 1, msg} =
             Stop.run(["dev"], %{ssh: ssh, leases: fn -> leases() end, reap_ms: 60_000})

    m = IO.iodata_to_binary(msg)
    assert m =~ "passwordless sudo" and m =~ "kill"
    # VM left running (not reaped)
    assert File.exists?(VzBeam.Pidfile.path("dev"))
  end

  test "recognizes macOS sudo denials without entering reap" do
    for output <- ["sudo: a password is required\n", "sudo: a terminal is required\n"] do
      ssh = fn _ -> {output, 1} end

      assert {:error, 1, message} =
               Stop.run(["dev"], %{ssh: ssh, leases: fn -> leases() end, reap_ms: 60_000})

      text = IO.iodata_to_binary(message)
      assert text =~ "sudoers"
      assert text =~ "kill dev"
      assert File.exists?(VzBeam.Pidfile.path("dev"))
    end
  end

  test "recognizes OpenBSD doas denials with a narrow nopass rule" do
    for output <- [
          "doas: Operation not permitted\n",
          "doas: a password is required\n",
          "doas is not enabled\n"
        ] do
      ssh = fn _ -> {output, 1} end

      assert {:error, 1, message} =
               Stop.run(["obsd"], %{ssh: ssh, leases: fn -> leases() end, reap_ms: 60_000})

      text = IO.iodata_to_binary(message)
      assert text =~ "permit nopass deploy as root cmd /sbin/shutdown args -p now"
      assert text =~ "vzbeam kill obsd"
      assert File.exists?(VzBeam.Pidfile.path("obsd"))
    end
  end

  test "ordinary SSH disconnect still reaps a successful shutdown" do
    ssh = fn _ ->
      File.rm(VzBeam.Pidfile.path("dev"))
      {"Connection to guest closed.\n", 255}
    end

    assert {:ok, message} =
             Stop.run(["dev"], %{ssh: ssh, leases: fn -> leases() end, reap_ms: 5_000})

    assert IO.iodata_to_binary(message) =~ "stopped dev"
  end

  test "unrecognized nonzero SSH status still follows normal reap timeout" do
    ssh = fn _ -> {"Connection timed out\n", 255} end

    assert {:error, 1, message} =
             Stop.run(["dev"], %{ssh: ssh, leases: fn -> leases() end, reap_ms: 0})

    assert IO.iodata_to_binary(message) =~ "did not stop in time"
  end

  test "refuses a stopped VM and a missing lease" do
    File.rm(VzBeam.Pidfile.path("dev"))

    assert {:error, 1, m1} =
             Stop.run(["dev"], %{ssh: fn _ -> {"", 0} end, leases: fn -> "" end, reap_ms: 0})

    assert IO.iodata_to_binary(m1) =~ "not running"
  end

  test "errors with no DHCP lease when VM is running but has no lease" do
    # pid file is already written by setup (VM is running)
    assert {:error, 1, msg} =
             Stop.run(["dev"], %{ssh: fn _ -> {"", 0} end, leases: fn -> "" end, reap_ms: 0})

    assert IO.iodata_to_binary(msg) =~ "no DHCP lease"
  end

  test "describes malformed and unsupported manifests with the stop prefix", %{home: home} do
    fixtures = [
      {"future", Jason.encode!(%{"schemaVersion" => 99, "guestOS" => "macos"}),
       "unsupported schema version 99"},
      {"unknown", Jason.encode!(%{"schemaVersion" => 2, "guestOS" => "plan9"}),
       "unsupported guest OS plan9"},
      {"malformed", "not-json", "invalid config.json"}
    ]

    for {name, body, expected} <- fixtures do
      File.mkdir_p!(Path.join(home, name))
      File.write!(Path.join([home, name, "config.json"]), body)
      assert {:error, 1, message} = Stop.run([name], %{})
      assert IO.iodata_to_binary(message) =~ "stop: #{expected}"
    end
  end
end
