defmodule VzBeam.Cache do
  @moduledoc "Cached restore images (IPSW) + index.json under $VZBEAM_HOME/cache/ipsw."
  alias VzBeam.{Home, AtomicFile}

  @spec dir() :: Path.t()
  def dir, do: Path.join([Home.root(), "cache", "ipsw"])

  @spec index_path() :: Path.t()
  def index_path, do: Path.join(dir(), "index.json")

  @spec read_index() :: map
  def read_index do
    with {:ok, body} <- File.read(index_path()),
         {:ok, %{} = m} <- Jason.decode(body) do
      m
    else
      _ -> %{"schemaVersion" => 1, "images" => %{}}
    end
  end

  @spec lookup(String.t()) :: {:ok, map} | :error
  def lookup(build) do
    case read_index()["images"][build] do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  @spec list() :: [map]
  def list, do: read_index()["images"] |> Map.values() |> Enum.sort_by(& &1["build"])

  @spec ensure(String.t(), map) :: {:ok, atom, map} | {:error, term}
  def ensure(spec, deps \\ default_deps()) do
    with {:ok, info} <- deps.image_info.(spec),
         :ok <- validate_build(info.build) do
      clear_stale_pending()
      final = Path.join(dir(), "#{info.build}.ipsw")

      case lookup(info.build) do
        {:ok, entry} -> {:ok, :cached, entry}
        :error -> if File.regular?(final),
                    do: with({:ok, e} <- put_index(info, final), do: {:ok, :reconciled, e}),
                    else: acquire(spec, info, final, deps)
      end
    end
  end

  defp acquire(spec, info, final, deps) do
    pending = "#{final}.#{System.unique_integer([:positive])}.pending"

    with :ok <- File.mkdir_p(dir()),
         :ok <- fetch_bytes(spec, info, pending, deps),
         :ok <- size_sane(pending),
         :ok <- File.rename(pending, final),
         {:ok, entry} <- put_index(info, final) do
      {:ok, :fetched, entry}
    else
      err -> File.rm(pending); err
    end
  end

  # Invoked INSIDE the with chain (after mkdir_p) so the cache dir exists before cp/curl writes.
  defp fetch_bytes("latest", info, pending, deps), do: deps.download.(info.url, pending)
  defp fetch_bytes(spec, _info, pending, deps), do: deps.copy.(spec, pending)

  defp put_index(info, final) do
    with {:ok, stat} <- File.stat(final) do
      entry = %{"version" => info.version, "build" => info.build, "file" => Path.basename(final),
                "source" => info.source, "url" => info.url, "bytes" => stat.size,
                "fetchedAt" => DateTime.utc_now() |> DateTime.to_iso8601()}

      index = read_index()
      images = Map.put(index["images"] || %{}, info.build, entry)
      case AtomicFile.write(index_path(), Jason.encode!(Map.put(index, "images", images), pretty: true)) do
        :ok -> {:ok, entry}
        err -> err
      end
    end
  end

  defp clear_stale_pending do
    case File.ls(dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".pending"))
        |> Enum.each(&File.rm_rf(Path.join(dir(), &1)))
      _ -> :ok
    end
  end

  # No expected size is available (image-info carries none), so only reject an empty file.
  defp size_sane(path) do
    case File.stat(path) do
      {:ok, %{size: s}} when s > 0 -> :ok
      _ -> {:error, :empty_image}
    end
  end

  defp validate_build(b) when is_binary(b) do
    if b != "" and b not in [".", ".."] and not String.contains?(b, ["/", "\\"]),
      do: :ok, else: {:error, :bad_build_token}
  end

  defp validate_build(_), do: {:error, :bad_build_token}

  defp default_deps do
    %{image_info: &VzBeam.Sidecar.image_info/1, download: &download/2, copy: &cp_clone/2}
  end

  defp cp_clone(src, dst) do
    case System.cmd("cp", ["-c", src, dst], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, {:copy_failed, String.trim(out)}}
    end
  end

  defp download(url, dst) do
    case System.cmd("curl", ["-fL", "-o", dst, url], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, {:download_failed, String.trim(out)}}
    end
  end
end
