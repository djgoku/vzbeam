defmodule VzBeam.SidecarTest do
  use ExUnit.Case, async: false
  alias VzBeam.Sidecar

  @fake Path.expand("support/fake_vz", __DIR__)

  setup do
    File.chmod!(@fake, 0o755)
    System.put_env("VZBEAM_VZ", @fake)
    on_exit(fn -> System.delete_env("VZBEAM_VZ") end)
    :ok
  end

  test "locate finds the binary via VZBEAM_VZ" do
    assert {:ok, @fake} = Sidecar.locate()
  end

  test "locate errors when nothing resolves" do
    System.put_env("VZBEAM_VZ", "/no/such/vz")
    assert {:error, :not_found} = Sidecar.locate()
  end

  test "check_version accepts protocol 1 (real subprocess, default runner)" do
    assert :ok = Sidecar.check_version()
  end

  test "image_info parses the image event (injected runner)" do
    runner = fn _p, ["image-info", "latest"], _ ->
      {~s({"type":"image","version":"26.5.1","build":"25F80","url":"u","source":"latest"}\n), 0}
    end
    assert {:ok, %{version: "26.5.1", build: "25F80", source: "latest"}} =
             Sidecar.image_info("latest", runner)
  end

  test "reid parses the reid event via the real fake_vz" do
    assert {:ok, %{machine_identifier: "NEW-ID", mac_address: "5e:11:22:33:44:55"}} = Sidecar.reid()
  end

  test "an error event maps to a typed VZ error (real fake_vz, exit 3)" do
    assert {:error, {:vz, "VZErrorDomain", 6, "max VMs"}} = Sidecar.call("errorcase", [])
  end

  test "truncated output surfaces as :unterminated" do
    runner = fn _p, _a, _ -> {~s({"type":"image","build":"25F80"}), 0} end  # no trailing newline
    assert {:error, :unterminated} = Sidecar.image_info("latest", runner)
  end

  test "non-zero exit dominates a terminal event (spec precedence)" do
    runner = fn _p, _a, _ -> {~s({"type":"image","version":"26","build":"X","url":"u","source":"s"}\n), 1} end
    assert {:error, {:exit, 1}} = VzBeam.Sidecar.image_info("latest", runner)
  end

  test "stream/4 yields progress events then the restored terminal (real Port + fake_vz)" do
    parent = self()

    assert {:ok, events} =
             Sidecar.stream(
               "restore",
               ~w(--ipsw x --disk d --aux a --disk-size 1 --cpu 1 --mem 1),
               fn ev -> send(parent, {:ev, ev}) end
             )

    assert Enum.any?(events, &match?({:event, "restored", _}, &1))
    assert_received {:ev, {:event, "progress", %{"fraction" => 0.5}}}
  end

  test "restore/1 returns the restored identity over the stream transport" do
    assert {:ok, %{machine_identifier: "RID", build: "25F80", version: "26.5.1"}} =
             Sidecar.restore(%{ipsw: "x", disk: "d", aux: "a", disk_size: 1, cpu: 1, mem: 1})
  end
end
