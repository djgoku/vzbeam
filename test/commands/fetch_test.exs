defmodule VzBeam.Commands.FetchTest do
  use ExUnit.Case, async: false

  test "prints version+build on a successful fetch" do
    deps = %{
      ensure: fn "/img.ipsw" -> {:ok, :fetched, %{"version" => "26.5.1", "build" => "25F80"}} end
    }

    assert {:ok, out} = VzBeam.Commands.Fetch.run(["/img.ipsw"], deps)
    assert IO.iodata_to_binary(out) =~ "26.5.1 (25F80)"
  end

  test "surfaces an error" do
    deps = %{ensure: fn _ -> {:error, :bad_build_token} end}
    assert {:error, 1, msg} = VzBeam.Commands.Fetch.run(["x"], deps)
    assert IO.iodata_to_binary(msg) =~ "bad_build_token"
  end

  test "protocol mismatch tells the user to rebuild the sidecar" do
    deps = %{ensure: fn _ -> {:error, {:incompatible, 1, 2}} end}

    assert {:error, 1, message} = VzBeam.Commands.Fetch.run(["latest"], deps)
    text = IO.iodata_to_binary(message)
    assert text =~ "protocol 1"
    assert text =~ "mix vz.build"
  end

  test "usage error with no spec mentions the URL spec kind" do
    assert {:error, 2, msg} = VzBeam.Commands.Fetch.run([], %{ensure: fn _ -> :unused end})
    assert IO.iodata_to_binary(msg) =~ "URL"
  end
end
