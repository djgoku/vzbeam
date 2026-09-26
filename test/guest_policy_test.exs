defmodule VzBeam.GuestPolicyTest do
  use ExUnit.Case, async: true
  alias VzBeam.GuestPolicy

  test "macOS policy preserves existing behavior" do
    manifest = %{"guestOS" => "macos"}

    assert GuestPolicy.guest(manifest) == :macos
    assert GuestPolicy.sidecar_guest(manifest) == "macos"
    assert GuestPolicy.ssh_user(manifest) == "admin"
    assert GuestPolicy.supports_share?(manifest)
    assert GuestPolicy.consumes_macos_slot?(manifest)
    assert GuestPolicy.shutdown_argv(manifest) == ["sudo", "-n", "shutdown", "-h", "now"]
    assert GuestPolicy.disk_growth_note(manifest) == :macos_recovery_partition

    assert GuestPolicy.os_label(manifest, %{"version" => "26.5.1", "build" => "25F80"}) ==
             "26.5.1 (25F80)"
  end

  test "OpenBSD policy selects generic behavior and stored SSH user" do
    manifest = %{"guestOS" => "openbsd", "sshUser" => "deploy"}

    assert GuestPolicy.guest(manifest) == :openbsd
    assert GuestPolicy.sidecar_guest(manifest) == "openbsd"
    assert GuestPolicy.ssh_user(manifest) == "deploy"
    refute GuestPolicy.supports_share?(manifest)
    refute GuestPolicy.consumes_macos_slot?(manifest)

    assert GuestPolicy.shutdown_argv(manifest) == [
             "doas",
             "-n",
             "/sbin/shutdown",
             "-p",
             "now"
           ]

    assert GuestPolicy.disk_growth_note(manifest) == :openbsd_unallocated_space
    assert GuestPolicy.os_label(manifest, %{"version" => "7.9"}) == "OpenBSD 7.9"
    assert GuestPolicy.os_label(manifest, %{}) == "OpenBSD"
  end
end
