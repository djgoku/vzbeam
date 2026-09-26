defmodule VzBeam.GuestPolicy do
  @moduledoc "Closed guest behavior mapping for normalized manifests."
  alias VzBeam.Defaults

  @spec guest(map) :: :macos | :openbsd
  def guest(%{"guestOS" => "macos"}), do: :macos
  def guest(%{"guestOS" => "openbsd"}), do: :openbsd

  @spec sidecar_guest(map) :: String.t()
  def sidecar_guest(manifest), do: manifest |> guest() |> Atom.to_string()

  @spec ssh_user(map) :: String.t()
  def ssh_user(manifest), do: manifest["sshUser"] || Defaults.values().ssh_user

  @spec supports_share?(map) :: boolean
  def supports_share?(manifest), do: guest(manifest) == :macos

  @spec consumes_macos_slot?(map) :: boolean
  def consumes_macos_slot?(manifest), do: guest(manifest) == :macos

  @spec shutdown_argv(map) :: [String.t()]
  def shutdown_argv(%{"guestOS" => "macos"}),
    do: ["sudo", "-n", "shutdown", "-h", "now"]

  def shutdown_argv(%{"guestOS" => "openbsd"}),
    do: ["doas", "-n", "/sbin/shutdown", "-p", "now"]

  @spec disk_growth_note(map) :: :macos_recovery_partition | :openbsd_unallocated_space
  def disk_growth_note(%{"guestOS" => "macos"}), do: :macos_recovery_partition
  def disk_growth_note(%{"guestOS" => "openbsd"}), do: :openbsd_unallocated_space

  @spec os_label(map, map) :: String.t()
  def os_label(%{"guestOS" => "macos"}, %{"version" => version, "build" => build}),
    do: "#{version} (#{build})"

  def os_label(%{"guestOS" => "macos"}, _image), do: "-"

  def os_label(%{"guestOS" => "openbsd"}, %{"version" => version}),
    do: "OpenBSD #{version}"

  def os_label(%{"guestOS" => "openbsd"}, _image), do: "OpenBSD"
end
