defmodule VzBeam.Commands.LsTest do
  use ExUnit.Case, async: false

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)

    base = %{
      "name" => "base",
      "base" => nil,
      "macAddress" => "5e:00",
      "cpuCount" => 4,
      "memoryBytes" => 8_589_934_592,
      "image" => %{"version" => "26.5.1", "build" => "25F80"}
    }

    write_bundle(home, "base", base)

    write_bundle(home, "dev", %{base | "name" => "dev", "base" => "base", "macAddress" => "5e:07"})

    on_exit(fn ->
      System.delete_env("VZBEAM_HOME")
      File.rm_rf!(home)
    end)

    :ok
  end

  defp write_bundle(home, name, map) do
    File.mkdir_p!(Path.join(home, name))
    File.write!(Path.join([home, name, "config.json"]), Jason.encode!(map))
  end

  test "lists bundles with header and rows" do
    {:ok, out} = VzBeam.Commands.Ls.run([], fn -> "" end)
    text = IO.iodata_to_binary(out)
    assert text =~ ~r/NAME\s+STATUS\s+BASE\s+OS/
    assert text =~ "base"
    assert text =~ "dev"
    assert text =~ "26.5.1 (25F80)"
    assert text =~ "stopped"
  end

  test "empty home prints just the header" do
    System.put_env(
      "VZBEAM_HOME",
      Path.join(System.tmp_dir!(), "empty-#{System.unique_integer([:positive])}")
    )

    {:ok, out} = VzBeam.Commands.Ls.run([], fn -> "" end)
    assert IO.iodata_to_binary(out) =~ "NAME"
  end

  test "renders OpenBSD labels and retains rows for invalid manifests" do
    home = System.get_env("VZBEAM_HOME")

    write_bundle(home, "obsd", %{
      "schemaVersion" => 2,
      "guestOS" => "openbsd",
      "name" => "obsd",
      "image" => %{"version" => "7.9"}
    })

    write_bundle(home, "custom", %{
      "schemaVersion" => 2,
      "guestOS" => "openbsd",
      "name" => "custom",
      "image" => %{"sha256" => "abc"}
    })

    write_bundle(home, "future", %{"schemaVersion" => 99, "guestOS" => "macos"})
    write_bundle(home, "unknown", %{"schemaVersion" => 2, "guestOS" => "plan9"})
    File.mkdir_p!(Path.join(home, "malformed"))
    File.write!(Path.join([home, "malformed", "config.json"]), "not-json")

    {:ok, output} = VzBeam.Commands.Ls.run([], fn -> "" end)
    text = IO.iodata_to_binary(output)
    assert text =~ "OpenBSD 7.9"
    assert text =~ ~r/custom\s+stopped.*OpenBSD/
    assert text =~ "future"
    assert text =~ "unsupported schema version 99"
    assert text =~ "unknown"
    assert text =~ "unsupported guest OS plan9"
    assert text =~ "malformed"
    assert text =~ "invalid config.json"
  end
end
