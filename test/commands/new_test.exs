defmodule VzBeam.Commands.NewTest do
  use ExUnit.Case, async: false
  alias VzBeam.{Commands.New, IsoCache, PendingBundle}

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    File.mkdir_p!(Path.join(home, "base"))

    File.write!(
      Path.join([home, "base", "config.json"]),
      Jason.encode!(%{
        "name" => "base",
        "base" => nil,
        "macAddress" => "5e:00",
        "machineIdentifier" => "OLD",
        "hardwareModel" => "HW",
        "cpuCount" => 4,
        "memoryBytes" => 8_589_934_592,
        "image" => %{"version" => "26.5.1", "build" => "25F80"}
      })
    )

    File.write!(Path.join([home, "base", "disk.img"]), "DISK")

    on_exit(fn ->
      System.delete_env("VZBEAM_HOME")
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  defp deps do
    %{
      reid: fn _guest -> {:ok, %{machine_identifier: "NEW", mac_address: "5e:ff"}} end,
      ensure: fn _ ->
        {:ok, :fetched, %{"version" => "26.5.1", "build" => "25F80", "file" => "25F80.ipsw"}}
      end,
      restore: fn opts, _report ->
        File.touch!(opts.aux)

        {:ok,
         %{
           machine_identifier: "RID",
           hardware_model: "HW2",
           mac_address: "5e:ab",
           version: "26.5.1",
           build: "25F80"
         }}
      end,
      ensure_iso: fn _ ->
        {:ok, :fetched,
         %{
           "kind" => "iso",
           "source" => "/tmp/install79.iso",
           "file" => "abc.iso",
           "sha256" => "abc",
           "version" => "7.9"
         }}
      end,
      install: fn opts, report ->
        File.touch!(opts.nvram)
        report.({:event, "install_started", %{"pid" => 123}})
        report.({:event, "installed", %{}})

        {:ok, %{machine_identifier: "OPENBSD-ID", mac_address: "5e:79:00:00:00:01"}}
      end,
      claim_pending: &PendingBundle.claim/1,
      cleanup_pending: &PendingBundle.cleanup/1,
      promote_pending: &PendingBundle.promote/1,
      progress: fn _io -> :ok end
    }
  end

  defp make_openbsd_base(home, name \\ "obsd-base") do
    dir = Path.join(home, name)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "config.json"),
      Jason.encode!(%{
        "schemaVersion" => 2,
        "guestOS" => "openbsd",
        "name" => name,
        "base" => nil,
        "image" => %{
          "kind" => "iso",
          "file" => "abc.iso",
          "sha256" => "abc",
          "version" => "7.9"
        },
        "machineIdentifier" => "OLD-OPENBSD-ID",
        "macAddress" => "5e:79:00:00:00:01",
        "sshUser" => "deploy",
        "cpuCount" => 2,
        "memoryBytes" => 2_147_483_648
      })
    )

    File.write!(Path.join(dir, "disk.img"), "OPENBSD-DISK")
    File.write!(Path.join(dir, "nvram.bin"), "OPENBSD-NVRAM")
  end

  test "clone copies the bundle and re-identifies it", %{home: home} do
    File.write!(Path.join([home, "base", "install-owner.json"]), "stray")
    parent = self()

    clone_deps = %{
      deps()
      | reid: fn guest ->
          send(parent, {:reid_guest, guest})
          {:ok, %{machine_identifier: "NEW", mac_address: "5e:ff"}}
        end
    }

    assert {:ok, _} = New.run(["dev", "base"], clone_deps)
    assert_received {:reid_guest, :macos}
    m = Jason.decode!(File.read!(Path.join([home, "dev", "config.json"])))
    assert m["base"] == "base" and m["machineIdentifier"] == "NEW" and m["macAddress"] == "5e:ff"
    assert m["schemaVersion"] == 2 and m["guestOS"] == "macos"
    # inherited
    assert m["cpuCount"] == 4
    # cloned
    assert File.read!(Path.join([home, "dev", "disk.img"])) == "DISK"
    refute File.exists?(Path.join([home, "dev", "install-owner.json"]))
    refute File.exists?(Path.join(home, "dev.pending"))
  end

  test "clone refuses a running base", %{home: _home} do
    :ok = VzBeam.Pidfile.write("base", System.pid())
    assert {:error, 1, msg} = New.run(["dev", "base"], deps())
    assert IO.iodata_to_binary(msg) =~ "running"
  end

  test "clone preserves OpenBSD state and re-identifies with a generic identity", %{home: home} do
    make_openbsd_base(home)
    parent = self()

    clone_deps = %{
      deps()
      | reid: fn guest ->
          send(parent, {:reid_guest, guest})

          {:ok, %{machine_identifier: "NEW-OPENBSD-ID", mac_address: "5e:79:00:00:00:02"}}
        end
    }

    assert {:ok, _} = New.run(["obsd-copy", "obsd-base"], clone_deps)
    assert_received {:reid_guest, :openbsd}
    manifest = Jason.decode!(File.read!(Path.join([home, "obsd-copy", "config.json"])))
    assert manifest["guestOS"] == "openbsd"
    assert manifest["sshUser"] == "deploy"
    assert manifest["image"]["sha256"] == "abc"
    assert manifest["machineIdentifier"] == "NEW-OPENBSD-ID"
    assert manifest["macAddress"] == "5e:79:00:00:00:02"
    assert File.read!(Path.join([home, "obsd-copy", "disk.img"])) == "OPENBSD-DISK"
    assert File.read!(Path.join([home, "obsd-copy", "nvram.bin"])) == "OPENBSD-NVRAM"
  end

  test "OpenBSD clone disk growth explains unallocated guest space", %{home: home} do
    make_openbsd_base(home)
    assert {:ok, message} = New.run(["obsd-copy", "obsd-base", "--disk-gb", "1"], deps())
    text = IO.iodata_to_binary(message)
    assert text =~ "unallocated"
    assert text =~ "OpenBSD"
    refute text =~ "recoveryOS"
  end

  test "clone describes malformed and unsupported base manifests", %{home: home} do
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
      assert {:error, 1, message} = New.run(["copy-#{name}", name], deps())
      assert IO.iodata_to_binary(message) =~ "new: #{expected}"
    end
  end

  test "clone refuses a reserved name" do
    assert {:error, 1, msg} = New.run(["cache", "base"], deps())
    assert IO.iodata_to_binary(msg) =~ "reserved"
  end

  test "restore creates a fresh base with disk.img + aux.img", %{home: home} do
    assert {:ok, _} = New.run(["fresh", "--image", "latest"], deps())
    assert File.regular?(Path.join([home, "fresh", "disk.img"]))
    assert File.regular?(Path.join([home, "fresh", "aux.img"]))
    m = Jason.decode!(File.read!(Path.join([home, "fresh", "config.json"])))
    assert m["base"] == nil and m["machineIdentifier"] == "RID"
    assert m["schemaVersion"] == 2 and m["guestOS"] == "macos"
    refute Map.has_key?(m, "sshUser")
  end

  test "--iso installs OpenBSD in pending and promotes a complete bundle", %{home: home} do
    assert {:ok, out} =
             New.run(
               [
                 "obsd",
                 "--iso",
                 "/tmp/install79.iso",
                 "--ssh-user",
                 "deploy",
                 "--resolution",
                 "1280x800"
               ],
               deps()
             )

    assert IO.iodata_to_binary(out) =~ "created obsd"
    manifest = Jason.decode!(File.read!(Path.join([home, "obsd", "config.json"])))
    assert manifest["guestOS"] == "openbsd"
    assert manifest["sshUser"] == "deploy"
    assert manifest["image"]["sha256"] == "abc"
    assert manifest["machineIdentifier"] == "OPENBSD-ID"
    refute Map.has_key?(manifest, "hardwareModel")
    assert File.regular?(Path.join([home, "obsd", "disk.img"]))
    assert File.regular?(Path.join([home, "obsd", "nvram.bin"]))
    refute File.exists?(Path.join(home, "obsd.pending"))
  end

  test "--iso announces user-specific installer instructions before starting", %{home: _home} do
    parent = self()
    base = deps()

    traced = %{
      base
      | progress: fn io -> send(parent, {:trace, :progress, IO.iodata_to_binary(io)}) end,
        install: fn opts, report ->
          send(parent, {:trace, :install})
          base.install.(opts, report)
        end
    }

    assert {:ok, _} =
             New.run(["obsd", "--iso", "x.iso", "--ssh-user", "deploy"], traced)

    assert_receive {:trace, :progress, iso_notice}
    assert iso_notice =~ "ISO"
    assert_receive {:trace, :progress, instructions}
    assert instructions =~ "deploy"
    assert instructions =~ "sshd"
    assert instructions =~ "halt -p"
    # The installer's own (H)alt runs plain `halt`, which never powers the VM off.
    assert instructions =~ "(S)hell"
    assert instructions =~ "answer `s`"
    assert instructions =~ "Closing the installer\nwindow only hides it"
    assert instructions =~ "Press Ctrl-C here to cancel the install"
    # Set apart from the ISO line before it and the installer progress after it.
    text = IO.iodata_to_binary(instructions)
    assert String.starts_with?(text, "\n") and String.ends_with?(text, "\n\n")
    assert for(<<c <- text>>, c >= 128, do: c) == [], "installer instructions contain non-ASCII"
    assert_receive {:trace, :install}
  end

  test "--iso validates media combinations, user, resolution, and pending names", %{home: home} do
    for args <- [
          ["obsd", "--iso", "x.iso", "--image", "latest"],
          ["obsd", "base", "--iso", "x.iso"],
          ["obsd"],
          ["obsd", "--iso", "x.iso", "--ssh-user", ""],
          ["obsd", "--iso", "x.iso", "--ssh-user", "root"],
          ["obsd", "--iso", "x.iso", "--ssh-user", "bad@host"],
          ["obsd", "--iso", "x.iso", "--resolution", "wide"],
          ["obsd.pending", "base"],
          ["obsd.pending", "--image", "latest"],
          ["obsd.pending", "--iso", "x.iso"]
        ] do
      assert {:error, 2, _} = New.run(args, deps())
      refute File.exists?(Path.join(home, "obsd"))
      refute File.exists?(Path.join(home, "obsd.pending"))
    end
  end

  test "--iso cleans its owned pending bundle on cancellation and startup failure", %{home: home} do
    failures = [
      {{:error, {:vz, "vz", 130, "install cancelled"}}, "cancelled"},
      {{:error, {:vz, "VZErrorDomain", 5, "startup failed"}}, "startup failed"}
    ]

    for {result, expected} <- failures do
      failing = %{deps() | install: fn _opts, _report -> result end}
      assert {:error, 1, message} = New.run(["obsd", "--iso", "x.iso"], failing)
      assert IO.iodata_to_binary(message) =~ expected
      refute File.exists?(Path.join(home, "obsd"))
      refute File.exists?(Path.join(home, "obsd.pending"))
    end
  end

  test "--iso describes missing and empty installation media", %{home: home} do
    media_deps = %{deps() | ensure_iso: &IsoCache.ensure/1}
    missing = Path.join(home, "missing.iso")
    empty = Path.join(home, "empty.iso")
    File.write!(empty, "")

    assert {:error, 1, missing_message} = New.run(["missing", "--iso", missing], media_deps)
    assert IO.iodata_to_binary(missing_message) =~ "missing or not a regular file"

    assert {:error, 1, empty_message} = New.run(["empty", "--iso", empty], media_deps)
    assert IO.iodata_to_binary(empty_message) =~ "ISO is empty"

    refute File.exists?(Path.join(home, "missing.pending"))
    refute File.exists?(Path.join(home, "empty.pending"))
  end

  test "promotion failure preserves the completed pending bundle", %{home: home} do
    preserving = %{deps() | promote_pending: fn _claim -> {:error, :lock_timeout} end}
    pending = Path.join(home, "obsd.pending")

    assert {:error, 1, message} = New.run(["obsd", "--iso", "x.iso"], preserving)
    text = IO.iodata_to_binary(message)
    assert text =~ "preserved"
    assert text =~ pending
    assert text =~ Path.join(home, "obsd")
    assert text =~ "install-owner.json"
    assert text =~ "Do not rerun"
    assert File.regular?(Path.join(pending, "disk.img"))
    assert File.regular?(Path.join(pending, "nvram.bin"))
    assert File.regular?(Path.join(pending, "config.json"))
  end

  # The installer has powered off, so the disk holds the user's interactive install: a
  # later failure keeps it and prints the config vzbeam could not write.
  test "a config write failure after the installer powers off preserves the install", %{
    home: home
  } do
    unwritable = %{
      deps()
      | install: fn opts, report ->
          File.touch!(opts.nvram)
          # A non-empty directory where config.json belongs makes the manifest write fail.
          File.mkdir_p!(Path.join([Path.dirname(opts.disk), "config.json", "blocker"]))
          report.({:event, "installed", %{}})
          {:ok, %{machine_identifier: "OPENBSD-ID", mac_address: "5e:79:00:00:00:01"}}
        end
    }

    pending = Path.join(home, "obsd.pending")

    assert {:error, 1, message} = New.run(["obsd", "--iso", "x.iso"], unwritable)
    text = IO.iodata_to_binary(message)
    assert text =~ "preserved at #{pending}"
    assert text =~ "Do not rerun"
    assert text =~ Path.join(pending, "config.json")
    assert text =~ Path.join([home, "obsd", "install-owner.json"])
    assert text =~ ~s("macAddress": "5e:79:00:00:00:01")
    assert text =~ ~s("machineIdentifier": "OPENBSD-ID")
    assert File.regular?(Path.join(pending, "disk.img"))
    assert File.regular?(Path.join(pending, "nvram.bin"))
  end

  test "a missing NVRAM after the installer powers off also preserves the disk", %{home: home} do
    no_nvram = %{
      deps()
      | install: fn _opts, report ->
          report.({:event, "installed", %{}})
          {:ok, %{machine_identifier: "OPENBSD-ID", mac_address: "5e:79:00:00:00:01"}}
        end
    }

    pending = Path.join(home, "obsd.pending")

    assert {:error, 1, message} = New.run(["obsd", "--iso", "x.iso"], no_nvram)
    assert IO.iodata_to_binary(message) =~ "preserved at #{pending}"
    assert File.regular?(Path.join(pending, "disk.img"))
  end

  test "protocol mismatch tells the user to rebuild the sidecar" do
    stale = %{deps() | reid: fn _guest -> {:error, {:incompatible, 1, 2}} end}

    assert {:error, 1, message} = New.run(["dev", "base"], stale)
    text = IO.iodata_to_binary(message)
    assert text =~ "protocol 1"
    assert text =~ "mix vz.build"
  end

  test "a bare final path is rejected before ISO acquisition", %{home: home} do
    final = Path.join(home, "obsd")
    File.mkdir_p!(final)

    no_media = %{
      deps()
      | ensure_iso: fn _ ->
          flunk("must reject the occupied final path before acquiring media")
        end
    }

    assert {:error, 1, message} = New.run(["obsd", "--iso", "x.iso"], no_media)
    assert IO.iodata_to_binary(message) =~ "bundle already exists"
  end

  test "ISO acquisition completes before the pending claim", %{home: _home} do
    parent = self()
    base = deps()

    ordered = %{
      base
      | ensure_iso: fn spec ->
          send(parent, :iso_ready)
          base.ensure_iso.(spec)
        end,
        claim_pending: fn name ->
          assert_received :iso_ready
          PendingBundle.claim(name)
        end
    }

    assert {:ok, _} = New.run(["obsd", "--iso", "x.iso"], ordered)
  end

  test "a live pending owner blocks creation without deleting its bytes", %{home: home} do
    assert {:ok, claim} = PendingBundle.claim("obsd")
    File.write!(Path.join(claim.path, "sentinel"), "live")

    assert {:error, 1, message} = New.run(["obsd", "--iso", "x.iso"], deps())
    assert IO.iodata_to_binary(message) =~ "creation already in progress"
    assert File.read!(Path.join([home, "obsd.pending", "sentinel"])) == "live"
  end

  test "a dead pending owner is reclaimed before installation", %{home: home} do
    pending = Path.join(home, "obsd.pending")
    File.mkdir_p!(pending)
    File.write!(Path.join(pending, "sentinel"), "stale")

    File.write!(
      Path.join(pending, "install-owner.json"),
      Jason.encode!(%{"pid" => 999_999, "startedAt" => "dead"})
    )

    assert {:ok, _} = New.run(["obsd", "--iso", "x.iso"], deps())
    refute File.exists?(Path.join([home, "obsd", "sentinel"]))
  end

  test "an ownerless pending bundle is preserved with actionable recovery guidance", %{home: home} do
    pending = Path.join(home, "obsd.pending")
    File.mkdir_p!(pending)
    File.write!(Path.join(pending, "sentinel"), "unknown")

    assert {:error, 1, message} = New.run(["obsd", "--iso", "x.iso"], deps())
    text = IO.iodata_to_binary(message)
    assert text =~ pending
    assert text =~ "verify no old `vzbeam new` is running"
    assert File.read!(Path.join(pending, "sentinel")) == "unknown"
  end

  test "--image is mutually exclusive with a base" do
    assert {:error, 2, _} = New.run(["dev", "base", "--image", "latest"], deps())
  end

  test "restore announces a cache hit and reports install progress", %{home: _home} do
    me = self()

    deps = %{
      deps()
      | ensure: fn _ ->
          {:ok, :cached, %{"version" => "26.5.1", "build" => "25F80", "file" => "25F80.ipsw"}}
        end,
        restore: fn opts, report ->
          File.touch!(opts.aux)
          report.({:event, "progress", %{"fraction" => 0.5}})
          report.({:event, "restored", %{}})

          {:ok,
           %{
             machine_identifier: "RID",
             hardware_model: "HW2",
             mac_address: "5e:ab",
             version: "26.5.1",
             build: "25F80"
           }}
        end,
        progress: fn io -> send(me, {:progress, IO.iodata_to_binary(io)}) end
    }

    assert {:ok, _} = New.run(["fresh", "--image", "https://h/x.ipsw"], deps)
    assert_received {:progress, "using cached image 26.5.1 (25F80)\n"}
    assert_received {:progress, "\rrestoring... 50%"}
    assert_received {:progress, "\rrestoring... 100%\n"}
  end

  test "restore announces a fresh fetch (not a cache hit)", %{home: _home} do
    me = self()
    deps = %{deps() | progress: fn io -> send(me, {:progress, IO.iodata_to_binary(io)}) end}
    assert {:ok, _} = New.run(["fresh", "--image", "https://h/x.ipsw"], deps)
    assert_received {:progress, "fetched 26.5.1 (25F80)\n"}
  end

  test "clone reclaims a dead owner's stale .pending and does not nest", %{home: home} do
    File.mkdir_p!(Path.join(home, "dev.pending"))
    File.write!(Path.join([home, "dev.pending", "junk"]), "stale")

    File.write!(
      Path.join([home, "dev.pending", "install-owner.json"]),
      Jason.encode!(%{"pid" => 999_999, "startedAt" => "dead"})
    )

    assert {:ok, _} = New.run(["dev", "base"], deps())
    # stale junk gone
    refute File.exists?(Path.join([home, "dev", "junk"]))
    # not nested
    refute File.exists?(Path.join([home, "dev", "base"]))
    assert File.exists?(Path.join([home, "dev", "config.json"]))
  end

  @gb 1024 * 1024 * 1024

  defp sparse!(path, size) do
    {:ok, :ok} = File.open(path, [:write, :raw], fn fd -> :file.pwrite(fd, size - 1, <<0>>) end)
  end

  test "clone honors --disk-gb by growing the cloned disk", %{home: home} do
    assert {:ok, msg} = New.run(["dev", "base", "--disk-gb", "2"], deps())
    assert IO.iodata_to_binary(msg) =~ "disk=2G"
    # inherits the base layout
    assert IO.iodata_to_binary(msg) =~ "recoveryOS"
    assert File.stat!(Path.join([home, "dev", "disk.img"])).size == 2 * @gb
    # base untouched
    assert File.stat!(Path.join([home, "base", "disk.img"])).size == 4
  end

  test "clone refuses a --disk-gb smaller than the base disk", %{home: home} do
    sparse!(Path.join([home, "base", "disk.img"]), 2 * @gb)
    assert {:error, 1, msg} = New.run(["dev", "base", "--disk-gb", "1"], deps())
    assert IO.iodata_to_binary(msg) =~ ">= the base disk (2G)"
    refute File.exists?(Path.join(home, "dev"))
  end

  test "clone honors --cpu and --mem-gb overrides", %{home: home} do
    assert {:ok, msg} = New.run(["dev", "base", "--cpu", "8", "--mem-gb", "16"], deps())
    assert IO.iodata_to_binary(msg) =~ "cpu=8 mem=16G"
    m = Jason.decode!(File.read!(Path.join([home, "dev", "config.json"])))
    assert m["cpuCount"] == 8 and m["memoryBytes"] == 16 * @gb
  end

  test "clone rejects non-positive cpu and memory overrides before creating a bundle", %{
    home: home
  } do
    for args <- [
          ["--cpu", "0"],
          ["--cpu", "-1"],
          ["--mem-gb", "0"],
          ["--mem-gb", "-1"],
          ["--disk-gb", "0"],
          ["--disk-gb", "-1"]
        ] do
      assert {:error, 2, msg} = New.run(["dev", "base" | args], deps())
      assert IO.iodata_to_binary(msg) =~ "must be >= 1"
      refute File.exists?(Path.join(home, "dev"))
      refute File.exists?(Path.join(home, "dev.pending"))
    end
  end

  test "restore rejects non-positive sizing overrides before creating a bundle", %{home: home} do
    for args <- [["--cpu", "0"], ["--mem-gb", "0"], ["--disk-gb", "0"]] do
      assert {:error, 2, msg} = New.run(["fresh", "--image", "latest" | args], deps())
      assert IO.iodata_to_binary(msg) =~ "must be >= 1"
      refute File.exists?(Path.join(home, "fresh"))
      refute File.exists?(Path.join(home, "fresh.pending"))
    end
  end

  test "rejects an unknown option" do
    assert {:error, 2, _} = New.run(["dev", "base", "--bogus", "x"], deps())
  end
end
