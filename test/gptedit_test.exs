defmodule VzBeam.GpteditTest do
  use ExUnit.Case, async: true

  test "destructive commands abort when hdiutil attachment detection fails" do
    {out, status} = run_remove("#!/bin/sh\nexit 1\n")

    assert status != 0
    assert out =~ "could not determine whether the image is attached"
    refute out =~ "Traceback"
  end

  test "destructive commands abort when hdiutil returns a plist with no images list" do
    plist = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>"
    {out, status} = run_remove("#!/bin/sh\nprintf '%s' '#{plist}'\n")

    assert status != 0
    assert out =~ "could not determine whether the image is attached"
    refute out =~ "Traceback"
  end

  test "destructive commands abort when hdiutil is unavailable" do
    {out, status} = run_remove(nil)

    assert status != 0
    assert out =~ "could not determine whether the image is attached"
    refute out =~ "Traceback"
  end

  test "destructive commands abort when hdiutil returns malformed XML" do
    {out, status} = run_remove("#!/bin/sh\nprintf '<plist><dict>'\n")

    assert status != 0
    assert out =~ "could not determine whether the image is attached"
    refute out =~ "Traceback"
  end

  test "destructive commands abort when an attachment record has an empty path" do
    plist =
      "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>images</key>" <>
        "<array><dict><key>image-path</key><string></string></dict></array></dict></plist>"

    {out, status} = run_remove("#!/bin/sh\nprintf '%s' '#{plist}'\n")

    assert status != 0
    assert out =~ "could not determine whether the image is attached"
    refute out =~ "Traceback"
  end

  defp run_remove(hdiutil_script) do
    dir = Path.join(System.tmp_dir!(), "vzbeam-gptedit-#{System.unique_integer([:positive])}")
    bin = Path.join(dir, "bin")
    image = Path.join(dir, "disk.img")
    hdiutil = Path.join(bin, "hdiutil")

    File.mkdir_p!(bin)
    File.write!(image, "not-a-gpt")

    if hdiutil_script do
      File.write!(hdiutil, hdiutil_script)
      File.chmod!(hdiutil, 0o755)
    end

    on_exit(fn -> File.rm_rf!(dir) end)

    script = Path.expand("../scripts/gptedit.py", __DIR__)

    System.cmd("python3", [script, "remove-recovery", image],
      env: [{"PATH", bin}],
      stderr_to_stdout: true
    )
  end
end
