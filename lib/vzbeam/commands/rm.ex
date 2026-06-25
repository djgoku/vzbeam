defmodule VzBeam.Commands.Rm do
  @moduledoc "rm <name> — delete a bundle (refuses if running; stop or kill it first)."
  alias VzBeam.{Home, Pidfile}

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run([name]) do
    cond do
      not Home.exists?(name) -> {:error, 1, ["no such bundle: ", name, "\n"]}
      Pidfile.running?(name) -> {:error, 1, [name, " is running; stop it first\n"]}
      true -> File.rm_rf!(Home.bundle_dir(name)); {:ok, ["removed ", name, "\n"]}
    end
  end

  def run(_), do: {:error, 2, "usage: vzbeam rm <name>\n"}
end
