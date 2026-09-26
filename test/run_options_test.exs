defmodule VzBeam.RunOptionsTest do
  use ExUnit.Case, async: true
  alias VzBeam.RunOptions

  test "parses normal, cached ISO, and one-shot ISO forms" do
    assert {:ok, %{name: "obsd", iso: nil}} = RunOptions.parse(["obsd"])

    assert {:ok, %{name: "obsd", iso: :cached, gui: true}} =
             RunOptions.parse(["obsd", "--iso"])

    assert {:ok, %{name: "obsd", iso: {:path, "/tmp/rescue.iso"}, gui: true}} =
             RunOptions.parse(["obsd", "--iso", "/tmp/rescue.iso"])

    assert {:ok, %{name: "obsd", iso: :cached}} = RunOptions.parse(["--iso", "obsd"])

    assert {:ok, %{name: "obsd", iso: {:path, "/tmp/rescue.iso"}}} =
             RunOptions.parse(["--iso", "/tmp/rescue.iso", "obsd"])

    assert {:ok, %{name: "obsd", iso: {:path, "/tmp/rescue.iso"}}} =
             RunOptions.parse(["--iso=/tmp/rescue.iso", "obsd"])
  end

  test "preserves option reordering and repeated-share last-value behavior" do
    assert {:ok,
            %{
              name: "obsd",
              gui: true,
              iso: {:path, "/tmp/rescue.iso"},
              share: "two=/b",
              resolution: "1280x800"
            }} =
             RunOptions.parse([
               "--gui",
               "obsd",
               "--share",
               "one=/a",
               "--iso",
               "/tmp/rescue.iso",
               "--resolution",
               "1280x800",
               "--share",
               "two=/b"
             ])
  end

  test "rejects ambiguous, repeated, and headless ISO input" do
    assert {:error, :iso_headless} = RunOptions.parse(["obsd", "--iso", "--headless"])
    assert {:error, :repeated_iso} = RunOptions.parse(["obsd", "--iso", "--iso"])
    assert {:error, :usage} = RunOptions.parse(["--iso"])
    assert {:error, :usage} = RunOptions.parse(["obsd", "--iso="])
    assert {:error, :usage} = RunOptions.parse(["obsd", "--no-iso"])
    assert {:error, :usage} = RunOptions.parse(["obsd", "extra", "third"])
  end

  test "rejects normal option errors and malformed shared resolutions" do
    assert {:error, :mode_conflict} = RunOptions.parse(["obsd", "--gui", "--headless"])
    assert {:error, :unknown_option} = RunOptions.parse(["obsd", "--bogus"])
    assert {:error, :bad_resolution} = RunOptions.parse(["obsd", "--resolution", "wide"])
    assert {:error, :usage} = RunOptions.parse(["obsd", "--resolution"])
    assert {:error, :usage} = RunOptions.parse(["obsd", "--share"])
  end
end
