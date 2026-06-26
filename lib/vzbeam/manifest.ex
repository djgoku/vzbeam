defmodule VzBeam.Manifest do
  @moduledoc "Read/write a bundle's config.json (atomic, schema-stamped)."
  alias VzBeam.{Home, AtomicFile}

  @schema_version 1

  @spec path(String.t()) :: Path.t()
  def path(name), do: Path.join(Home.bundle_dir(name), "config.json")

  @spec read(String.t()) :: {:ok, map} | {:error, term}
  def read(name) do
    with {:ok, body} <- File.read(path(name)),
         {:ok, map} <- Jason.decode(body) do
      {:ok, map}
    end
  end

  @spec read_or(String.t(), term) :: {:ok, map} | {:error, term}
  def read_or(name, error) do
    case read(name) do
      {:ok, m} -> {:ok, m}
      _ -> {:error, error}
    end
  end

  @spec write_to(Path.t(), map) :: :ok | {:error, term}
  def write_to(path, map) do
    AtomicFile.write(path, Jason.encode!(Map.put(map, "schemaVersion", @schema_version), pretty: true))
  end
end
