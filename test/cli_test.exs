defmodule VzBeam.CLITest do
  use ExUnit.Case, async: true

  test "no args returns usage as an error" do
    assert {:error, 2, usage} = VzBeam.CLI.run([])
    assert IO.iodata_to_binary(usage) =~ "Usage: vzbeam"
  end

  test "--help returns usage as ok" do
    assert {:ok, usage} = VzBeam.CLI.run(["--help"])
    assert IO.iodata_to_binary(usage) =~ "ls"
  end

  test "unknown verb errors with exit code 2" do
    assert {:error, 2, msg} = VzBeam.CLI.run(["bogus"])
    assert IO.iodata_to_binary(msg) =~ "unknown command: bogus"
  end
end
