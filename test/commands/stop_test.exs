defmodule VzBeam.Commands.StopTest do
  use ExUnit.Case, async: false
  alias VzBeam.Commands.Stop

  @mac "5e:aa:bb:cc:dd:ee"

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-stop-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    dir = Path.join(home, "dev")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "config.json"), Jason.encode!(%{"name" => "dev", "macAddress" => @mac}))
    :ok = VzBeam.Pidfile.write("dev", System.pid())  # running
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    {:ok, home: home}
  end

  defp leases, do: "{\n\tname=dev\n\tip_address=192.168.64.7\n\thw_address=1,#{@mac}\n}\n"

  test "issues a key-based, BatchMode, sudo -n shutdown and reaps on pid disappearance" do
    parent = self()

    ssh = fn args ->
      send(parent, {:ssh, args})
      File.rm(VzBeam.Pidfile.path("dev"))  # simulate guest shutdown -> process gone
      {"", 0}
    end

    assert {:ok, msg} = Stop.run(["dev"], %{ssh: ssh, leases: fn -> leases() end, reap_ms: 5_000})
    assert IO.iodata_to_binary(msg) =~ "stopped dev"
    assert_received {:ssh, args}
    joined = Enum.join(args, " ")
    assert joined =~ "BatchMode=yes" and joined =~ "sudo -n shutdown -h now" and joined =~ "admin@192.168.64.7"
    refute File.exists?(VzBeam.Pidfile.path("dev"))
  end

  test "times out when the VM does not stop" do
    ssh = fn _ -> {"", 0} end  # does nothing; pid stays alive
    assert {:error, 1, msg} = Stop.run(["dev"], %{ssh: ssh, leases: fn -> leases() end, reap_ms: 0})
    assert IO.iodata_to_binary(msg) =~ "kill"
  end

  test "refuses a stopped VM and a missing lease" do
    File.rm(VzBeam.Pidfile.path("dev"))
    assert {:error, 1, m1} = Stop.run(["dev"], %{ssh: fn _ -> {"", 0} end, leases: fn -> "" end, reap_ms: 0})
    assert IO.iodata_to_binary(m1) =~ "not running"
  end

  test "errors with no DHCP lease when VM is running but has no lease" do
    # pid file is already written by setup (VM is running)
    assert {:error, 1, msg} = Stop.run(["dev"], %{ssh: fn _ -> {"", 0} end, leases: fn -> "" end, reap_ms: 0})
    assert IO.iodata_to_binary(msg) =~ "no DHCP lease"
  end
end
