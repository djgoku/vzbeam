defmodule VzBeam.Commands.SshTest do
  use ExUnit.Case, async: false
  alias VzBeam.Commands.Ssh

  @mac "5e:aa:bb:cc:dd:ee"

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-ssh-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    dir = Path.join(home, "dev")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "config.json"), Jason.encode!(%{"name" => "dev", "macAddress" => @mac}))
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    :ok
  end

  defp leases, do: "{\n\tname=dev\n\tip_address=192.168.64.7\n\thw_address=1,#{@mac}\n}\n"

  test "one-shot `-- cmd` builds key-based argv and propagates output + exit code" do
    parent = self()
    run_cmd = fn args -> send(parent, {:cmd, args}); {"hi\n", 0} end
    deps = %{leases: fn -> leases() end, run_cmd: run_cmd, interactive: fn _ -> 0 end}

    assert {:ok, "hi\n"} = Ssh.run(["dev", "--", "uname", "-a"], deps)
    assert_received {:cmd, args}
    joined = Enum.join(args, " ")
    assert joined =~ "BatchMode=yes" and joined =~ "admin@192.168.64.7"
    assert List.last(args) == "-a" and Enum.at(args, -2) == "uname"
  end

  test "one-shot propagates a non-zero remote exit code" do
    deps = %{leases: fn -> leases() end, run_cmd: fn _ -> {"boom\n", 3} end, interactive: fn _ -> 0 end}
    assert {:error, 3, "boom\n"} = Ssh.run(["dev", "--", "false"], deps)
  end

  test "interactive (no cmd) returns the ssh exit code via the injected port runner" do
    deps = %{leases: fn -> leases() end, run_cmd: fn _ -> {"", 0} end, interactive: fn _args -> 0 end}
    assert {:ok, ""} = Ssh.run(["dev"], deps)

    deps2 = %{deps | interactive: fn _ -> 7 end}
    assert {:error, 7, ""} = Ssh.run(["dev"], deps2)
  end

  test "errors when there is no lease" do
    deps = %{leases: fn -> "" end, run_cmd: fn _ -> {"", 0} end, interactive: fn _ -> 0 end}
    assert {:error, 1, msg} = Ssh.run(["dev"], deps)
    assert IO.iodata_to_binary(msg) =~ "no DHCP lease"
  end

  test "usage error is pure ASCII (the escript renders non-ASCII as \\x{...})" do
    assert {:error, 2, msg} = Ssh.run([], %{})
    bin = IO.iodata_to_binary(msg)
    assert for(<<c <- bin>>, c >= 128, do: c) == [], "ssh usage contains non-ASCII"
  end
end
