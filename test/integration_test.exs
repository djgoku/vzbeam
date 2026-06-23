defmodule VzBeam.IntegrationTest do
  use ExUnit.Case, async: false

  test "ls runs end-to-end through CLI.run with a populated home" do
    home = Path.join(System.tmp_dir!(), "vzbeam-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "base"))
    File.write!(Path.join([home, "base", "config.json"]), Jason.encode!(%{"name" => "base"}))
    System.put_env("VZBEAM_HOME", home)
    assert {:ok, out} = VzBeam.CLI.run(["ls"])
    assert IO.iodata_to_binary(out) =~ "base"
  after
    System.delete_env("VZBEAM_HOME")
  end
end
