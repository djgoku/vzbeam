defmodule VzBeam.Manifest do
  @moduledoc "Read a bundle's config.json (written by Commands.New at create time)."
  alias VzBeam.Home

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
end
