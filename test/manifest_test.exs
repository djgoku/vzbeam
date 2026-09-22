defmodule VzBeam.ManifestTest do
  use ExUnit.Case, async: false

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "base"))
    System.put_env("VZBEAM_HOME", home)

    on_exit(fn ->
      System.delete_env("VZBEAM_HOME")
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "read returns the decoded config.json" do
    File.write!(
      Path.join([System.get_env("VZBEAM_HOME"), "base", "config.json"]),
      Jason.encode!(%{"name" => "base", "macAddress" => "5e:aa"})
    )

    assert {:ok, %{"name" => "base", "macAddress" => "5e:aa", "guestOS" => "macos"}} =
             VzBeam.Manifest.read("base")
  end

  test "read of a missing manifest errors" do
    assert {:error, _} = VzBeam.Manifest.read("ghost")
  end

  test "read_or returns the map or the caller's error" do
    File.write!(
      Path.join([System.get_env("VZBEAM_HOME"), "base", "config.json"]),
      Jason.encode!(%{"name" => "base"})
    )

    assert {:ok, %{"name" => "base", "guestOS" => "macos"}} =
             VzBeam.Manifest.read_or("base", :nope)

    assert {:error, :nope} = VzBeam.Manifest.read_or("ghost", :nope)
  end

  test "write_to stamps schemaVersion and round-trips via read" do
    :ok =
      VzBeam.Manifest.write_to(VzBeam.Manifest.path("base"), %{
        "name" => "base",
        "macAddress" => "5e:aa"
      })

    assert {:ok,
            %{
              "name" => "base",
              "macAddress" => "5e:aa",
              "schemaVersion" => 2,
              "guestOS" => "macos"
            }} =
             VzBeam.Manifest.read("base")
  end

  test "schema 1 and absent schema normalize to macOS without dropping keys" do
    assert {:ok, %{"guestOS" => "macos", "future" => 7}} =
             VzBeam.Manifest.normalize(%{"schemaVersion" => 1, "future" => 7})

    assert {:ok, %{"guestOS" => "macos", "name" => "old"}} =
             VzBeam.Manifest.normalize(%{"name" => "old"})
  end

  test "legacy read is non-mutating and the next write upgrades while preserving keys" do
    path = VzBeam.Manifest.path("base")
    legacy = %{"schemaVersion" => 1, "name" => "base", "future" => %{"x" => 1}}
    File.write!(path, Jason.encode!(legacy))

    assert {:ok, %{"guestOS" => "macos"}} = VzBeam.Manifest.read("base")
    assert Jason.decode!(File.read!(path)) == legacy

    :ok = VzBeam.Manifest.write_to(path, Map.put(legacy, "cpuCount", 8))
    upgraded = Jason.decode!(File.read!(path))
    assert upgraded["schemaVersion"] == 2
    assert upgraded["guestOS"] == "macos"
    assert upgraded["future"] == %{"x" => 1}
  end

  test "schema 2 validates guestOS and future schemas fail explicitly" do
    assert {:ok, %{"guestOS" => "openbsd"}} =
             VzBeam.Manifest.normalize(%{"schemaVersion" => 2, "guestOS" => "openbsd"})

    assert {:error, :invalid_manifest} =
             VzBeam.Manifest.normalize(%{"schemaVersion" => 2})

    assert {:error, {:unsupported_guest, "plan9"}} =
             VzBeam.Manifest.normalize(%{"schemaVersion" => 2, "guestOS" => "plan9"})

    assert {:error, {:unsupported_schema, 3}} =
             VzBeam.Manifest.normalize(%{"schemaVersion" => 3, "guestOS" => "macos"})

    assert {:error, :invalid_manifest} = VzBeam.Manifest.normalize([])
  end

  test "read_or maps only an absent file to the caller's missing error" do
    assert {:error, :no_such_bundle} =
             VzBeam.Manifest.read_or("ghost", :no_such_bundle)

    File.write!(VzBeam.Manifest.path("base"), "not-json")

    assert {:error, :invalid_manifest} =
             VzBeam.Manifest.read_or("base", :no_such_bundle)
  end

  test "manifest failures have stable operator-facing descriptions" do
    assert VzBeam.Manifest.describe_error(:invalid_manifest) == "invalid config.json"

    assert VzBeam.Manifest.describe_error({:unsupported_schema, 3}) ==
             "unsupported schema version 3 (supports up to 2)"

    assert VzBeam.Manifest.describe_error({:unsupported_guest, "plan9"}) ==
             "unsupported guest OS plan9"
  end
end
