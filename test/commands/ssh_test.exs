defmodule VzBeam.Commands.SshTest do
  use ExUnit.Case, async: false
  alias VzBeam.Commands.Ssh

  @mac "5e:aa:bb:cc:dd:ee"

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-ssh-#{System.unique_integer([:positive])}")
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

  test "one-shot `-- cmd` hands key-based argv to ssh and relays nothing itself" do
    parent = self()

    ssh = fn args ->
      send(parent, {:ssh, args})
      0
    end

    deps = %{leases: fn -> leases() end, ssh: ssh}

    # ssh writes to the terminal directly, so the command's output never passes
    # through vzbeam (binary-safe, streamed, and stdout stays stdout).
    assert {:ok, ""} = Ssh.run(["dev", "--", "uname", "-a"], deps)
    assert_received {:ssh, args}
    joined = Enum.join(args, " ")
    assert joined =~ "BatchMode=yes" and joined =~ "admin@192.168.64.7"
    assert List.last(args) == "-a" and Enum.at(args, -2) == "uname"
  end

  test "one-shot propagates a non-zero remote exit code" do
    deps = %{leases: fn -> leases() end, ssh: fn _ -> 3 end}
    assert {:error, 3, ""} = Ssh.run(["dev", "--", "false"], deps)
  end

  test "OpenBSD SSH uses the stored per-bundle user" do
    parent = self()

    deps = %{
      leases: fn -> leases() end,
      ssh: fn args ->
        send(parent, {:ssh, args})
        0
      end
    }

    assert {:ok, ""} = Ssh.run(["obsd", "--", "true"], deps)
    assert_received {:ssh, args}
    assert Enum.join(args, " ") =~ "deploy@192.168.64.8"
  end

  test "interactive (no cmd) returns the ssh exit code via the injected port runner" do
    deps = %{leases: fn -> leases() end, ssh: fn _args -> 0 end}
    assert {:ok, ""} = Ssh.run(["dev"], deps)

    deps2 = %{deps | ssh: fn _ -> 7 end}
    assert {:error, 7, ""} = Ssh.run(["dev"], deps2)
  end

  # A child BEAM whose stdout we capture: bytes the spawned program writes must arrive
  # untouched (the old capture-then-IO.write path raised ArgumentError on non-UTF-8).
  test "the ssh port passes the program's stdout through byte-for-byte and returns its status" do
    ebin = Path.join(:code.lib_dir(:vzbeam), "ebin")

    script = ~S"""
    status = VzBeam.Commands.Ssh.ssh_port(["-c", "printf '\\377\\000\\376'; exit 3"], "/bin/sh")
    System.halt(status)
    """

    assert {<<255, 0, 254>>, 3} =
             System.cmd(System.find_executable("elixir"), ["-pa", ebin, "-e", script])
  end

  test "errors when there is no lease" do
    deps = %{leases: fn -> "" end, ssh: fn _ -> 0 end}
    assert {:error, 1, msg} = Ssh.run(["dev"], deps)
    assert IO.iodata_to_binary(msg) =~ "no DHCP lease"
  end

  test "usage error is pure ASCII (the escript renders non-ASCII as \\x{...})" do
    assert {:error, 2, msg} = Ssh.run([], %{})
    bin = IO.iodata_to_binary(msg)
    assert for(<<c <- bin>>, c >= 128, do: c) == [], "ssh usage contains non-ASCII"
  end

  test "describes malformed and unsupported manifests with the ssh prefix", %{home: home} do
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
      assert {:error, 1, message} = Ssh.run([name], %{})
      assert IO.iodata_to_binary(message) =~ "ssh: #{expected}"
    end
  end
end
