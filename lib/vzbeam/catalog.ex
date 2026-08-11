defmodule VzBeam.Catalog do
  @moduledoc """
  Apple's published macOS IPSW catalog (mesu.apple.com) — the set of images
  Apple currently offers, which is exactly the set VZMacOSInstaller can
  restore (it refuses builds Apple has stopped signing). The catalog is a
  plist; `plutil` (ships with macOS) converts it to JSON for parsing.
  """

  @url "https://mesu.apple.com/assets/macos/com_apple_macOSIPSW/com_apple_macOSIPSW.xml"
  @device "VirtualMac2,1"

  @doc "List the images Apple currently offers for VZ VMs."
  @spec list(map) :: {:ok, [map]} | {:error, term}
  def list(deps \\ default_deps()) do
    with {:ok, plist} <- deps.get.(@url),
         {:ok, json} <- plist_to_json(plist, deps),
         {:ok, data} <- Jason.decode(json) do
      {:ok, extract(data)}
    end
  end

  @doc "Resolve a build id (case-insensitive) to its catalog entry."
  @spec resolve(String.t(), map) :: {:ok, map} | {:error, term}
  def resolve(build, deps \\ default_deps()) do
    with {:ok, entries} <- list(deps) do
      down = String.downcase(build)

      case Enum.find(entries, &(String.downcase(&1["build"]) == down)) do
        nil -> {:error, {:unknown_build, build}}
        entry -> {:ok, entry}
      end
    end
  end

  # plutil only reads files, so the fetched plist takes a round-trip through
  # an exclusively created file in a private directory. The directory itself
  # is created atomically, preventing cross-process collisions and symlink
  # pre-seeding in the shared system temp directory.
  defp plist_to_json(plist, deps) do
    make_tmp_dir = Map.get(deps, :make_tmp_dir, &make_tmp_dir/0)

    with {:ok, dir} <- make_tmp_dir.() do
      tmp = Path.join(dir, "catalog.plist")

      try do
        with {:ok, :ok} <- File.open(tmp, [:write, :binary, :exclusive], &IO.binwrite(&1, plist)) do
          case System.cmd("plutil", ["-convert", "json", "-o", "-", tmp], stderr_to_stdout: true) do
            {json, 0} -> {:ok, json}
            {out, _} -> {:error, {:plutil_failed, String.trim(out)}}
          end
        end
      after
        File.rm_rf(dir)
      end
    end
  end

  defp make_tmp_dir do
    template = Path.join(System.tmp_dir!(), "vzbeam-catalog.XXXXXX")

    case System.cmd("mktemp", ["-d", template], stderr_to_stdout: true) do
      {dir, 0} -> {:ok, String.trim(dir)}
      {out, _} -> {:error, {:mktemp_failed, String.trim(out)}}
    end
  end

  # Each device lists builds keyed by id, plus an "Unknown"/"Universal" nest
  # that repeats the same restore; the pattern match keeps only the direct
  # build entries.
  defp extract(data) do
    for {_epoch, %{"MobileDeviceSoftwareVersions" => by_device}} <-
          data["MobileDeviceSoftwareVersionsByVersion"] || %{},
        {@device, by_build} <- by_device,
        {_build, %{"Restore" => r}} <- by_build,
        is_binary(r["FirmwareURL"]) do
      %{"version" => r["ProductVersion"], "build" => r["BuildVersion"], "url" => r["FirmwareURL"]}
    end
    |> Enum.uniq()
    |> Enum.sort_by(& &1["build"], :desc)
  end

  defp default_deps, do: %{get: &http_get/1}

  # Same https-pinned curl posture as Cache.download; -sS keeps it quiet
  # (the catalog is ~100KB, no progress bar needed) but still prints errors.
  defp http_get(url) do
    case System.cmd("curl", ["-fsSL", "--proto", "=https", "--proto-redir", "=https", url],
           stderr_to_stdout: true) do
      {body, 0} -> {:ok, body}
      {out, code} -> {:error, {:catalog_fetch_failed, "curl exited #{code}: #{String.trim(out)}"}}
    end
  end
end
