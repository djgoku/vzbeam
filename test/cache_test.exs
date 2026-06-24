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
      copy: fn _src, dst -> File.mkdir_p!(Path.dirname(dst)); File.write(dst, "IPSWBYTES") end,
      download: fn _url, _dst -> {:error, :should_not_download} end
    }
  end

  test "ensure fetches, indexes, and is idempotent" do
    assert {:ok, :fetched, e} = Cache.ensure("/tmp/x.ipsw", deps())
    assert e["build"] == "25F80" and e["file"] == "25F80.ipsw"
    assert File.regular?(Path.join(Cache.dir(), "25F80.ipsw"))
    assert {:ok, :cached, _} = Cache.ensure("/tmp/x.ipsw", deps())
    assert [%{"build" => "25F80"}] = Cache.list()
  end

  test "ensure reconciles an orphaned final file into the index (finding #1)" do
    File.mkdir_p!(Cache.dir())
    File.write!(Path.join(Cache.dir(), "25F80.ipsw"), "ORPHAN")
    assert {:ok, :reconciled, e} = Cache.ensure("/tmp/x.ipsw", deps())
    assert e["build"] == "25F80"
    assert {:ok, _} = Cache.lookup("25F80")
  end

  test "ensure rejects an unsafe build token (finding #7)" do
    assert {:error, :bad_build_token} = Cache.ensure("/tmp/x.ipsw", deps("../evil"))
  end
end
