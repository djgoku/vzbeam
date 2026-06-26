defmodule VzBeam.Sidecar.BuildTest do
  use ExUnit.Case, async: true
  alias VzBeam.Sidecar.Build

  test "compiles, resolves the product path, and ad-hoc-signs it with the entitlement" do
    parent = self()

    runner = fn
      "swift", ["build", "-c", "release", "--package-path", "swift"], _opts ->
        send(parent, :compiled)
        {"", 0}

      "swift", ["build", "-c", "release", "--show-bin-path", "--package-path", "swift"], _opts ->
        {"/tmp/binpath\n", 0}

      "codesign", ["--force", "--sign", "-", "--entitlements", ent, product], _opts ->
        send(parent, {:signed, ent, product})
        {"", 0}
    end

    assert {:ok, "/tmp/binpath/vz"} = Build.build_and_sign("swift", runner)
    assert_received :compiled
    assert_received {:signed, "swift/vz.entitlements", "/tmp/binpath/vz"}
  end

  test "returns an error tuple when swift build fails" do
    runner = fn "swift", ["build", "-c", "release", "--package-path", _], _ -> {"", 65} end
    assert {:error, msg} = Build.build_and_sign("swift", runner)
    assert msg =~ "swift build"
  end
end
