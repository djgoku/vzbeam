defmodule VzBeam.Commands.LsTest do
  use ExUnit.Case, async: false

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    base = %{"name" => "base", "base" => nil, "macAddress" => "5e:00",
             "cpuCount" => 4, "memoryBytes" => 8_589_934_592,
             "image" => %{"version" => "26.5.1", "build" => "25F80"}}
    write_bundle(home, "base", base)
    write_bundle(home, "dev", %{base | "name" => "dev", "base" => "base", "macAddress" => "5e:07"})
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
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
    System.put_env("VZBEAM_HOME", Path.join(System.tmp_dir!(), "empty-#{System.unique_integer([:positive])}"))
    {:ok, out} = VzBeam.Commands.Ls.run([], fn -> "" end)
    assert IO.iodata_to_binary(out) =~ "NAME"
  end
end
