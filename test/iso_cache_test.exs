defmodule VzBeam.IsoCacheTest do
  use ExUnit.Case, async: false
  alias VzBeam.IsoCache

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-iso-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    System.put_env("VZBEAM_HOME", home)

    on_exit(fn ->
      System.delete_env("VZBEAM_HOME")
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "ensure hashes, stores, and deduplicates local ISO bytes", %{home: home} do
    source = Path.join(home, "install79.iso")
    File.write!(source, "openbsd-media")

    assert {:ok, :fetched, entry} = IsoCache.ensure(source)
    assert entry["kind"] == "iso"
    assert entry["source"] == Path.expand(source)
    assert entry["version"] == "7.9"
    assert entry["file"] == entry["sha256"] <> ".iso"
    assert File.read!(Path.join(IsoCache.dir(), entry["file"])) == "openbsd-media"
    assert {:ok, :cached, ^entry} = IsoCache.ensure(source)
  end

  test "official basenames infer versions and arbitrary names do not" do
    assert IsoCache.infer_version("install79.iso") == "7.9"
    assert IsoCache.infer_version("cd79.iso") == "7.9"
    assert IsoCache.infer_version("INSTALL79.ISO") == "7.9"
    assert IsoCache.infer_version("recovery.iso") == nil
  end

  test "rejects remote, missing, directory, and empty media", %{home: home} do
    assert {:error, :not_local_file} =
             IsoCache.ensure("https://cdn.example/install79.iso")

    assert {:error, :not_regular} = IsoCache.ensure(Path.join(home, "missing.iso"))
    assert {:error, :not_regular} = IsoCache.ensure(home)

    empty = Path.join(home, "empty.iso")
    File.touch!(empty)
    assert {:error, :empty_iso} = IsoCache.ensure(empty)
  end

  test "copy failure removes only the current pending file", %{home: home} do
    source = Path.join(home, "install79.iso")
    File.write!(source, "openbsd-media")
    File.mkdir_p!(IsoCache.dir())
    orphan = Path.join(IsoCache.dir(), "old-crash.pending")
    File.write!(orphan, "partial")

    deps = %{
      hash: &IsoCache.sha256/1,
      copy: fn _src, dst ->
        File.write!(dst, "partial-current")
        {:error, :copy_broke}
      end
    }

    assert {:error, :copy_broke} = IsoCache.ensure(source, deps)
    assert File.read!(orphan) == "partial"
    assert Path.wildcard(Path.join(IsoCache.dir(), "*.pending")) == [orphan]
  end

  test "source mutation during acquisition is rejected and cleaned up", %{home: home} do
    source = Path.join(home, "install79.iso")
    File.write!(source, "openbsd-media")

    deps = %{
      hash: &IsoCache.sha256/1,
      copy: fn src, dst ->
        :ok = File.write(src, "changed-after-first-hash")
        File.cp(src, dst)
      end
    }

    assert {:error, :source_changed} = IsoCache.ensure(source, deps)
    assert Path.wildcard(Path.join(IsoCache.dir(), "*.pending")) == []
  end

  test "a corrupt digest-named cache file is replaced from valid source bytes", %{home: home} do
    source = Path.join(home, "install79.iso")
    File.write!(source, "openbsd-media")
    assert {:ok, :fetched, entry} = IsoCache.ensure(source)

    cached = Path.join(IsoCache.dir(), entry["file"])
    File.write!(cached, "corrupt")

    assert {:ok, :fetched, ^entry} = IsoCache.ensure(source)
    assert File.read!(cached) == "openbsd-media"
  end

  test "cached references distinguish corrupt and missing bytes", %{home: home} do
    source = Path.join(home, "install79.iso")
    File.write!(source, "openbsd-media")
    assert {:ok, :fetched, entry} = IsoCache.ensure(source)

    cached = Path.join(IsoCache.dir(), entry["file"])
    digest = entry["sha256"]
    File.write!(cached, "corrupt")

    assert {:error, {:corrupt_cached_iso, ^digest}} =
             IsoCache.resolve_cached(%{"image" => entry})

    File.rm!(cached)

    assert {:error, {:missing_cached_iso, ^digest}} =
             IsoCache.resolve_cached(%{"image" => entry})

    expected_source = Path.expand(source)
    assert {:ok, ^expected_source} = IsoCache.validate_one_shot(source)
  end

  test "one-shot validation rejects invalid media without caching", %{home: home} do
    empty = Path.join(home, "empty.iso")
    File.touch!(empty)

    assert {:error, :not_local_file} = IsoCache.validate_one_shot("ftp://example/x.iso")
    assert {:error, :not_regular} = IsoCache.validate_one_shot(Path.join(home, "missing.iso"))
    assert {:error, :empty_iso} = IsoCache.validate_one_shot(empty)
    refute File.exists?(IsoCache.dir())
  end

  test "successful acquisition leaves unrelated orphan pending files alone", %{home: home} do
    source = Path.join(home, "recovery.iso")
    File.write!(source, "openbsd-media")
    File.mkdir_p!(IsoCache.dir())
    orphan = Path.join(IsoCache.dir(), "old-crash.pending")
    File.write!(orphan, "partial")

    assert {:ok, :fetched, entry} = IsoCache.ensure(source)
    assert entry["version"] == nil
    assert File.read!(orphan) == "partial"
  end
end
