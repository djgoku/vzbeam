defmodule VzBeam.SshConnTest do
  use ExUnit.Case, async: false
  alias VzBeam.SshConn

  @mac "5e:aa:bb:cc:dd:ee"

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-sshconn-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    :ok
  end

  test "args/1 includes BatchMode=yes, the private key, and admin@ip" do
    args = SshConn.args("192.168.64.5")
    joined = Enum.join(args, " ")
    assert joined =~ "BatchMode=yes"
    assert joined =~ "admin@192.168.64.5"
    # private key arg is present
    key = VzBeam.Keys.private()
    assert Enum.member?(args, key)
    assert Enum.member?(args, "-i")
  end

  test "resolve_ip/2 returns {:ok, ip} when MAC matches" do
    leases = "{\n\tname=dev\n\tip_address=192.168.64.7\n\thw_address=1,#{@mac}\n}\n"
    manifest = %{"macAddress" => @mac}
    assert {:ok, "192.168.64.7"} = SshConn.resolve_ip(manifest, leases)
  end

  test "resolve_ip/2 returns {:error, :no_lease} when MAC is not found" do
    manifest = %{"macAddress" => @mac}
    assert {:error, :no_lease} = SshConn.resolve_ip(manifest, "")
  end
end
