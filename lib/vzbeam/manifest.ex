defmodule VzBeam.Manifest do
  @moduledoc "Read/write a bundle's config.json (atomic, schema-stamped)."
  alias VzBeam.Home

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

  @spec write(String.t(), map) :: :ok | {:error, term}
  def write(name, map) when is_map(map) do
    stamped = Map.put(map, "schemaVersion", @schema_version)
    VzBeam.AtomicFile.write(path(name), Jason.encode!(stamped, pretty: true))
  end
end
