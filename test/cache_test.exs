defmodule VzBeam.CacheTest do
  use ExUnit.Case, async: false
  alias VzBeam.Cache

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    {:ok, home: home}
  end

  defp deps(build \\ "25F80") do
    %{
      image_info: fn _ -> {:ok, %{version: "26.5.1", build: build, url: "file:///x", source: "local"}} end,
      copy: fn _src, dst -> File.write(dst, "IPSWBYTES") end,
      download: fn _url, _dst -> {:error, :should_not_download} end
    }
  end

  defp url_deps(build \\ "25F80") do
    %{
      image_info: fn _path ->
        {:ok, %{version: "26.5.1", build: build, url: "https://cdn.example/redirect.ipsw", source: "local"}}
      end,
      download: fn _url, dst -> File.write(dst, "IPSWBYTES") end,
      copy: fn _s, _d -> {:error, :should_not_copy} end
    }
  end

  test "ensure fetches, indexes, and is idempotent" do
    assert {:ok, :fetched, e} = Cache.ensure("/tmp/x.ipsw", deps())
    assert e["build"] == "25F80" and e["file"] == "25F80.ipsw"
    assert File.regular?(Path.join(Cache.dir(), "25F80.ipsw"))
    assert {:ok, :cached, _} = Cache.ensure("/tmp/x.ipsw", deps())
    assert [%{"build" => "25F80"}] = Cache.list()
  end

  test "ensure reconciles an orphaned final file into the index" do
    File.mkdir_p!(Cache.dir())
    File.write!(Path.join(Cache.dir(), "25F80.ipsw"), "ORPHAN")
    assert {:ok, :reconciled, e} = Cache.ensure("/tmp/x.ipsw", deps())
    assert e["build"] == "25F80"
    assert {:ok, _} = Cache.lookup("25F80")
  end

  test "ensure rejects an unsafe build token" do
    assert {:error, :bad_build_token} = Cache.ensure("/tmp/x.ipsw", deps("../evil"))
  end

  test "ensure leaves unrelated *.pending files alone (no concurrent-fetch sweep)" do
    File.mkdir_p!(Cache.dir())
    File.write!(Path.join(Cache.dir(), "OLD.ipsw.99.pending"), "partial")
    assert {:ok, :fetched, _} = Cache.ensure("/tmp/x.ipsw", deps())
    assert File.exists?(Path.join(Cache.dir(), "OLD.ipsw.99.pending"))
  end

  test "ensure creates the cache dir before copying (real cp -c)" do
    src = Path.join(System.tmp_dir!(), "vzb-src-#{System.unique_integer([:positive])}.ipsw")
    File.write!(src, "ipsw-bytes")
    on_exit(fn -> File.rm(src) end)

    real_copy = fn s, d ->
      case System.cmd("cp", ["-c", s, d], stderr_to_stdout: true) do
        {_, 0} -> :ok
        {out, _} -> {:error, {:copy_failed, String.trim(out)}}
      end
    end

    deps = %{
      image_info: fn _ -> {:ok, %{version: "26.5.1", build: "25F80", url: "file:///x", source: "local"}} end,
      download: fn _u, _d -> {:error, :should_not_download} end,
      copy: real_copy
    }

    assert {:ok, :fetched, _e} = Cache.ensure(src, deps)
    assert File.regular?(Path.join(Cache.dir(), "25F80.ipsw"))
  end

  test "ensure fetches an https URL, overriding source/url and indexing by build" do
    assert {:ok, :fetched, e} = Cache.ensure("https://host.example/x.ipsw", url_deps())
    assert e["build"] == "25F80"
    assert e["file"] == "25F80.ipsw"
    assert e["source"] == "url"
    assert e["url"] == "https://host.example/x.ipsw"
    assert File.regular?(Path.join(Cache.dir(), "25F80.ipsw"))
  end

  test "ensure rejects a non-https URL scheme" do
    assert {:error, :unsupported_url_scheme} = Cache.ensure("http://host.example/x.ipsw", url_deps())
  end

  test "ensure rejects a non-http unsupported scheme" do
    assert {:error, :unsupported_url_scheme} = Cache.ensure("ftp://host.example/x.ipsw", url_deps())
  end

  test "ensure rejects an https URL with no host" do
    assert {:error, :bad_url} = Cache.ensure("https://", url_deps())
  end

  test "ensure cleans up the pending file when image-info fails on a URL fetch" do
    deps = %{url_deps() | image_info: fn _ -> {:error, :boom} end}
    assert {:error, :boom} = Cache.ensure("https://host.example/x.ipsw", deps)
    assert Path.wildcard(Path.join(Cache.dir(), "url-fetch-*.ipsw")) == []
  end

  test "ensure rejects an https URL carrying userinfo" do
    assert {:error, :url_userinfo_not_allowed} =
             Cache.ensure("https://user:pass@host.example/x.ipsw", url_deps())
  end

  test "ensure strips the fragment when storing a URL entry" do
    assert {:ok, :fetched, e} = Cache.ensure("https://host.example/x.ipsw#part1", url_deps())
    assert e["url"] == "https://host.example/x.ipsw"
    refute e["url"] =~ "#"
  end
end
