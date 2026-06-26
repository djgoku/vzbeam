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
    case classify(spec) do
      :url -> ensure_url(spec, deps)
      :bad_scheme -> {:error, :unsupported_url_scheme}
      :local -> ensure_cached_or_local(spec, deps)
    end
  end

  # A bare spec that exactly matches a cached build id (the BUILD column shown
  # by `vzbeam images`) resolves straight from the cache — no sidecar, no copy —
  # so `--image 26A5368g` works instead of re-typing the path or URL. `latest`,
  # real paths, and unknown tokens don't match a build id and fall through.
  # (Edge: a bare local filename equal to a cached build id takes the alias;
  # give it an `.ipsw`/path to force the local flow — IPSWs always have one.)
  defp ensure_cached_or_local(spec, deps) do
    case lookup_by_build(spec) do
      {:ok, entry} -> {:ok, :cached, entry}
      :error -> ensure_local(spec, deps)
    end
  end

  # Case-insensitive: Apple build ids are mixed-case (e.g. 26A5368g) and
  # effectively case-unique, so a case-fold match is forgiving without being
  # ambiguous. Scoped to this user-typed alias only — `lookup/1` stays exact
  # for the internal post-`image-info` dedup. O(n) over a handful of images.
  defp lookup_by_build(build) do
    down = String.downcase(build)

    entry =
      read_index()["images"]
      |> Map.values()
      |> Enum.find(&(is_binary(&1["build"]) and String.downcase(&1["build"]) == down))

    if entry && File.regular?(Path.join(dir(), entry["file"])),
      do: {:ok, entry},
      else: :error
  end

  # Classify by URI scheme, not string prefix: a bare "user:pass@host/path"
  # parses to scheme "user" and must be rejected, not treated as a local path.
  # "latest" and real paths parse to scheme nil -> local.
  defp classify(spec) do
    case URI.parse(spec).scheme do
      "https" -> :url
      nil -> :local
      _ -> :bad_scheme
    end
  end

  defp ensure_local(spec, deps) do
    with {:ok, info} <- deps.image_info.(spec),
         :ok <- validate_build(info.build) do
      final = Path.join(dir(), "#{info.build}.ipsw")

      case lookup(info.build) do
        {:ok, entry} -> {:ok, :cached, entry}
        :error -> if File.regular?(final),
                    do: with({:ok, e} <- put_index(info, final), do: {:ok, :reconciled, e}),
                    else: acquire(spec, info, final, deps)
      end
    end
  end

  # URL fetch: download first (the sidecar can't read a remote IPSW's metadata),
  # then identify the local file. `build` stays the canonical key.
  defp ensure_url(spec, deps) do
    with {:ok, url} <- normalize_url(spec) do
      case lookup_by_url(url) do
        {:ok, entry} -> {:ok, :cached, entry}
        :error -> acquire_url(url, deps)
      end
    end
  end

  # Pre-download shortcut only: an exact normalized-URL hit whose file still exists.
  defp lookup_by_url(url) do
    entry = read_index()["images"] |> Map.values() |> Enum.find(&(&1["url"] == url))

    if entry && File.regular?(Path.join(dir(), entry["file"])),
      do: {:ok, entry},
      else: :error
  end

  defp normalize_url(spec) do
    uri = URI.parse(spec)

    cond do
      uri.host in [nil, ""] -> {:error, :bad_url}
      uri.userinfo not in [nil, ""] -> {:error, :url_userinfo_not_allowed}
      true -> {:ok, URI.to_string(%{uri | fragment: nil})}
    end
  end

  defp acquire_url(url, deps) do
    pending = Path.join(dir(), "url-fetch-#{System.unique_integer([:positive])}.ipsw")

    with :ok <- File.mkdir_p(dir()),
         :ok <- deps.download.(url, pending),
         :ok <- size_sane(pending),
         {:ok, info} <- identify_url(pending, url, deps),
         :ok <- validate_build(info.build) do
      place_url(pending, Path.join(dir(), "#{info.build}.ipsw"), info)
    else
      err -> File.rm(pending); err
    end
  end

  # image-info reports the CDN redirect URL + "local"; override with the original
  # request URL + "url" so a later fetch of the same URL dedups (Task 3).
  defp identify_url(pending, url, deps) do
    with {:ok, info} <- deps.image_info.(pending), do: {:ok, %{info | url: url, source: "url"}}
  end

  defp place_url(pending, final, info) do
    case lookup(info.build) do
      {:ok, entry} ->
        File.rm(pending)
        {:ok, :cached, entry}

      :error ->
        if File.regular?(final) do
          File.rm(pending)
          with {:ok, e} <- put_index(info, final), do: {:ok, :reconciled, e}
        else
          with :ok <- File.rename(pending, final),
               {:ok, entry} <- put_index(info, final) do
            {:ok, :fetched, entry}
          else
            err -> File.rm(pending); err
          end
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

  # --progress-bar streams a live meter to the terminal (stderr) so a multi-GB
  # fetch is visibly working instead of looking hung; without it, capturing
  # curl's output left the user with a silent, frozen-looking terminal.
  # --proto/--proto-redir keep the request (and any redirect) on https.
  defp download(url, dst) do
    args = ["-fL", "--progress-bar", "--proto", "=https", "--proto-redir", "=https", "-o", dst, url]

    case System.cmd("curl", args) do
      {_, 0} -> :ok
      {_, code} -> {:error, {:download_failed, "curl exited #{code}"}}
    end
  end
end
