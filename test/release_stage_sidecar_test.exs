defmodule VzBeam.Release.StageSidecarTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias VzBeam.Release.StageSidecar

  setup do
    work = Path.join(System.tmp_dir!(), "stage-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(work, "lib/vzbeam-0.1.0"))
    product = Path.join(work, "built-vz")
    File.write!(product, "FAKE-VZ-BYTES")
    on_exit(fn -> File.rm_rf(work) end)
    %{work: work, product: product}
  end

  test "stage/2 copies the built product into the payload priv/ as an executable",
       %{work: work, product: product} do
    ctx = %{work_dir: work}
    # with_io/1 swallows the "burrito: staged signed vz -> ..." line so the suite stays quiet.
    {result, _io} = ExUnit.CaptureIO.with_io(fn -> StageSidecar.stage(ctx, fn -> {:ok, product} end) end)
    assert ^ctx = result
    dest = Path.join(work, "lib/vzbeam-0.1.0/priv/vz")
    assert File.read!(dest) == "FAKE-VZ-BYTES"
    assert (File.stat!(dest).mode &&& 0o111) != 0
  end

  test "stage/2 raises when the build helper fails", %{work: work} do
    assert_raise RuntimeError, ~r/vz sidecar staging failed/, fn ->
      StageSidecar.stage(%{work_dir: work}, fn -> {:error, "boom"} end)
    end
  end
end
