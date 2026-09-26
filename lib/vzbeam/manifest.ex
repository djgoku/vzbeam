defmodule VzBeam.Manifest do
  @moduledoc "Read/write a bundle's config.json (atomic, schema-stamped)."
  alias VzBeam.{Home, AtomicFile}

  @schema_version 2
  @guests ~w(macos openbsd)

  @spec path(String.t()) :: Path.t()
  def path(name), do: Path.join(Home.bundle_dir(name), "config.json")

  @spec read(String.t()) :: {:ok, map} | {:error, term}
  def read(name) do
    with {:ok, body} <- File.read(path(name)),
         {:ok, map} <- Jason.decode(body),
         {:ok, normalized} <- normalize(map) do
      {:ok, normalized}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_manifest}
      error -> error
    end
  end

  @spec read_or(String.t(), term) :: {:ok, map} | {:error, term}
  def read_or(name, missing_error) do
    case read(name) do
      {:error, :enoent} -> {:error, missing_error}
      result -> result
    end
  end

  @spec write_to(Path.t(), map) :: :ok | {:error, term}
  def write_to(path, map) do
    with {:ok, body} <- encode(map), do: AtomicFile.write(path, body)
  end

  @doc "The exact config.json body `write_to/2` writes for `map`."
  @spec encode(map) :: {:ok, String.t()} | {:error, term}
  def encode(map) do
    with {:ok, normalized} <- normalize(map) do
      stamped = Map.put(normalized, "schemaVersion", @schema_version)
      {:ok, Jason.encode!(stamped, pretty: true)}
    end
  end

  @spec normalize(term) :: {:ok, map} | {:error, term}
  def normalize(%{} = map) do
    version = Map.get(map, "schemaVersion", 1)
    guest = Map.get(map, "guestOS", if(version == 1, do: "macos"))

    cond do
      not is_integer(version) -> {:error, :invalid_manifest}
      version > @schema_version -> {:error, {:unsupported_schema, version}}
      version < 1 -> {:error, :invalid_manifest}
      not is_binary(guest) -> {:error, :invalid_manifest}
      guest not in @guests -> {:error, {:unsupported_guest, guest}}
      true -> {:ok, Map.put(map, "guestOS", guest)}
    end
  end

  def normalize(_), do: {:error, :invalid_manifest}

  @spec describe_error(term) :: String.t()
  def describe_error(:invalid_manifest), do: "invalid config.json"

  def describe_error({:unsupported_schema, version}),
    do: "unsupported schema version #{version} (supports up to #{@schema_version})"

  def describe_error({:unsupported_guest, guest}), do: "unsupported guest OS #{guest}"
end
