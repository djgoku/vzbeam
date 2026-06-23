defmodule VzBeam.HomeTest do
  use ExUnit.Case, async: false

  test "root honors VZBEAM_HOME env" do
    System.put_env("VZBEAM_HOME", "/tmp/vzbeam-test-home")
    assert VzBeam.Home.root() == "/tmp/vzbeam-test-home"
  after
    System.delete_env("VZBEAM_HOME")
  end

  test "root defaults under ~/.local/share/vzbeam" do
    System.delete_env("VZBEAM_HOME")
    assert VzBeam.Home.root() == Path.expand("~/.local/share/vzbeam")
  end

  test "bundles lists only dirs containing config.json" do
    home = Path.join(System.tmp_dir!(), "vzbeam-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "base"))
    File.write!(Path.join([home, "base", "config.json"]), "{}")
    File.mkdir_p!(Path.join(home, "notabundle"))
    System.put_env("VZBEAM_HOME", home)
    assert VzBeam.Home.bundles() == ["base"]
  after
    System.delete_env("VZBEAM_HOME")
  end
end
