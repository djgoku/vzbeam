defmodule VzBeam.Release.StageSidecarTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias VzBeam.Release.StageSidecar

  setup do
    work = Path.join(System.tmp_dir!(), "stage-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(work, "lib/vzbeam-0.1.0"))
    # `mix release --overwrite` keeps lib dirs from previously built versions;
    # staging must target the current release version, not a glob.
    File.mkdir_p!(Path.join(work, "lib/vzbeam-0.0.9"))
    product = Path.join(work, "built-vz")
    File.write!(product, "FAKE-VZ-BYTES")
    on_exit(fn -> File.rm_rf(work) end)
    ctx = %{work_dir: work, mix_release: %{version: "0.1.0"}}
    %{work: work, product: product, ctx: ctx}
  end

  test "stage/2 copies the built product into the current version's priv/ as an executable",
       %{work: work, product: product, ctx: ctx} do
    # with_io/1 swallows the "burrito: staged signed vz -> ..." line so the suite stays quiet.
    {result, _io} = ExUnit.CaptureIO.with_io(fn -> StageSidecar.stage(ctx, fn -> {:ok, product} end) end)
    assert ^ctx = result
    dest = Path.join(work, "lib/vzbeam-0.1.0/priv/vz")
    assert File.read!(dest) == "FAKE-VZ-BYTES"
    assert (File.stat!(dest).mode &&& 0o111) != 0
    refute File.exists?(Path.join(work, "lib/vzbeam-0.0.9/priv/vz"))
  end

  test "stage/2 raises when the build helper fails", %{ctx: ctx} do
    assert_raise RuntimeError, ~r/vz sidecar staging failed/, fn ->
      StageSidecar.stage(ctx, fn -> {:error, "boom"} end)
    end
  end

  test "stage/2 raises when the current version's app dir is missing",
       %{work: work, product: product} do
    ctx = %{work_dir: work, mix_release: %{version: "0.3.0"}}

    assert_raise RuntimeError, ~r/lib\/vzbeam-0\.3\.0/, fn ->
      StageSidecar.stage(ctx, fn -> {:ok, product} end)
    end
  end
end
