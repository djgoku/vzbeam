defmodule VzBeam.IsoCache do
  @moduledoc "Content-addressed retention and validation for local ISO media."
  alias VzBeam.Home

  @chunk 1_048_576

  @spec dir() :: Path.t()
  def dir, do: Path.join([Home.root(), "cache", "iso"])

  @spec ensure(Path.t(), map) :: {:ok, :fetched | :cached, map} | {:error, term}
  def ensure(source, deps \\ default_deps()) do
    with {:ok, expanded} <- validate_local(source),
         :ok <- File.mkdir_p(dir()),
         {:ok, digest} <- deps.hash.(expanded) do
      entry = entry(expanded, digest)
      final = Path.join(dir(), entry["file"])

      case verified_digest(final, digest, deps.hash) do
        :ok -> {:ok, :cached, entry}
        {:error, _reason} -> acquire(expanded, final, digest, entry, deps)
      end
    end
  end

  @spec validate_one_shot(Path.t()) :: {:ok, Path.t()} | {:error, term}
  def validate_one_shot(source), do: validate_local(source)

  @spec resolve_cached(map) ::
          {:ok, Path.t()}
          | {:error, {:missing_cached_iso | :corrupt_cached_iso, String.t()}}
          | {:error, :invalid_iso_reference}
  def resolve_cached(%{"image" => %{"sha256" => digest, "file" => file}})
      when is_binary(digest) and is_binary(file) do
    if Path.basename(file) == file do
      path = Path.join(dir(), file)

      cond do
        not File.regular?(path) -> {:error, {:missing_cached_iso, digest}}
        verified_digest(path, digest, &sha256/1) == :ok -> {:ok, path}
        true -> {:error, {:corrupt_cached_iso, digest}}
      end
    else
      {:error, :invalid_iso_reference}
    end
  end

  def resolve_cached(_manifest), do: {:error, :invalid_iso_reference}

  @spec sha256(Path.t()) :: {:ok, String.t()} | {:error, term}
  def sha256(path) do
    try do
      digest =
        path
        |> File.stream!(@chunk)
        |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)

      {:ok, digest}
    rescue
      error in File.Error -> {:error, error.reason}
    end
  end

  @spec infer_version(Path.t()) :: String.t() | nil
  def infer_version(path) do
    case Regex.run(~r/^(?:install|cd)(\d)(\d)\.iso$/i, Path.basename(path)) do
      [_, major, minor] -> major <> "." <> minor
      _ -> nil
    end
  end

  defp validate_local(source) when is_binary(source) do
    if URI.parse(source).scheme do
      {:error, :not_local_file}
    else
      expanded = Path.expand(source)

      case File.stat(expanded) do
        {:ok, %{type: :regular, size: size}} when size > 0 -> {:ok, expanded}
        {:ok, %{type: :regular}} -> {:error, :empty_iso}
        _ -> {:error, :not_regular}
      end
    end
  end

  defp validate_local(_source), do: {:error, :not_local_file}

  defp verified_digest(path, digest, hash) do
    case hash.(path) do
      {:ok, ^digest} -> :ok
      {:ok, _other} -> {:error, :digest_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp acquire(source, final, digest, entry, deps) do
    pending =
      Path.join(
        dir(),
        "#{digest}.#{System.pid()}.#{System.unique_integer([:positive])}.pending"
      )

    result =
      with :ok <- deps.copy.(source, pending),
           :ok <- verified_digest(pending, digest, deps.hash),
           :ok <- File.rename(pending, final) do
        {:ok, :fetched, entry}
      else
        {:error, :digest_mismatch} -> {:error, :source_changed}
        error -> error
      end

    File.rm(pending)
    result
  end

  defp entry(source, digest) do
    %{
      "kind" => "iso",
      "source" => source,
      "file" => digest <> ".iso",
      "sha256" => digest
    }
    |> maybe_put("version", infer_version(source))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp default_deps, do: %{hash: &sha256/1, copy: &copy_clone/2}

  defp copy_clone(source, destination) do
    case System.cmd("cp", ["-c", source, destination], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {_clone_output, _status} ->
        File.rm(destination)

        case System.cmd("cp", [source, destination], stderr_to_stdout: true) do
          {_, 0} -> :ok
          {output, _status} -> {:error, {:copy_failed, String.trim(output)}}
        end
    end
  end
end
