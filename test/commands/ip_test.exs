defmodule VzBeam.Commands.IpTest do
  use ExUnit.Case, async: false

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "base"))
    System.put_env("VZBEAM_HOME", home)

    File.write!(
      Path.join([home, "base", "config.json"]),
      Jason.encode!(%{
        "schemaVersion" => 2,
        "guestOS" => "openbsd",
        "name" => "base",
        "macAddress" => "5e:aa:bb:cc:dd:ee",
        "sshUser" => "deploy"
      })
    )

    on_exit(fn ->
      System.delete_env("VZBEAM_HOME")
      File.rm_rf!(home)
    end)

    :ok
  end

  @leases "{\n\tip_address=192.168.64.7\n\thw_address=1,5e:aa:bb:cc:dd:ee\n}\n"

  test "prints the IP for a known bundle" do
    assert {:ok, out} = VzBeam.Commands.Ip.run(["base"], fn -> @leases end)
    assert IO.iodata_to_binary(out) =~ "192.168.64.7"
  end

  test "errors when no lease is found" do
    assert {:error, 1, msg} = VzBeam.Commands.Ip.run(["base"], fn -> "" end)
    assert IO.iodata_to_binary(msg) =~ "no DHCP lease"
  end

  test "errors when the bundle is missing" do
    assert {:error, 1, _} = VzBeam.Commands.Ip.run(["ghost"], fn -> @leases end)
  end

  test "errors on missing argument" do
    assert {:error, 2, _} = VzBeam.Commands.Ip.run([])
  end

  test "errors gracefully when macAddress is null" do
    home = System.get_env("VZBEAM_HOME")

    File.write!(
      Path.join([home, "base", "config.json"]),
      Jason.encode!(%{"name" => "base", "macAddress" => nil})
    )

    assert {:error, 1, msg} = VzBeam.Commands.Ip.run(["base"], fn -> "" end)
    assert IO.iodata_to_binary(msg) =~ "no macAddress"
  end

  test "describes malformed and unsupported manifests with the ip prefix" do
    home = System.get_env("VZBEAM_HOME")

    for {body, expected} <- [
          {Jason.encode!(%{"schemaVersion" => 99, "guestOS" => "macos"}),
           "unsupported schema version 99"},
          {Jason.encode!(%{"schemaVersion" => 2, "guestOS" => "plan9"}),
           "unsupported guest OS plan9"},
          {"not-json", "invalid config.json"}
        ] do
      File.write!(Path.join([home, "base", "config.json"]), body)
      assert {:error, 1, message} = VzBeam.Commands.Ip.run(["base"], fn -> @leases end)
      assert IO.iodata_to_binary(message) =~ "ip: #{expected}"
    end
  end
end
