defmodule VzBeam.Home do
  @moduledoc "Resolves $VZBEAM_HOME and bundle paths."

  @spec root() :: Path.t()
  def root do
    case System.get_env("VZBEAM_HOME") do
      nil -> Path.expand("~/.local/share/vzbeam")
      "" -> Path.expand("~/.local/share/vzbeam")
      dir -> dir
    end
  end

  @spec bundle_dir(String.t()) :: Path.t()
  def bundle_dir(name), do: Path.join(root(), name)

  @spec bundles() :: [String.t()]
  def bundles do
    case File.ls(root()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&File.regular?(Path.join([root(), &1, "config.json"])))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end
end
