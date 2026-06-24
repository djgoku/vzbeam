defmodule VzBeam.Commands.Fetch do
  @moduledoc "fetch <latest|PATH> — download/cache a restore image."

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run(args), do: run(args, %{ensure: &VzBeam.Cache.ensure/1})

  def run([spec], %{ensure: ensure}) do
    case ensure.(spec) do
      {:ok, status, e} -> {:ok, [verb(status), " ", e["version"], " (", e["build"], ")\n"]}
      {:error, reason} -> {:error, 1, ["fetch failed: ", inspect(reason), "\n"]}
    end
  end

  def run(_, _), do: {:error, 2, "usage: vzbeam fetch <latest|PATH>\n"}

  defp verb(:cached), do: "already cached"
  defp verb(_), do: "fetched"
end
