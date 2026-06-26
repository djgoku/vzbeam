defmodule VzBeam.Commands.Set do
  @moduledoc "set <name> [--cpu N] [--mem-gb M] — change a stopped VM's CPU/RAM."
  alias VzBeam.{Manifest, Pidfile}

  @gb 1024 * 1024 * 1024

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: [cpu: :integer, mem_gb: :integer])

    cond do
      invalid != [] -> {:error, 2, "set: invalid option\n"}
      not match?([_], positional) or opts == [] -> usage()
      true -> apply_set(hd(positional), opts)
    end
  end

  defp apply_set(name, opts) do
    with :ok <- validate(opts),
         {:ok, m} <- Manifest.read_or(name, :no_such_bundle),
         :ok <- refute_running(name),
         updated = update(m, opts),
         :ok <- Manifest.write_to(Manifest.path(name), updated) do
      {:ok, ["set ", name, ": cpu=", to_string(updated["cpuCount"]),
             " mem=", to_string(div(updated["memoryBytes"], @gb)), "G\n"]}
    else
      err -> error(name, err)
    end
  end

  defp validate(opts) do
    cond do
      is_integer(opts[:cpu]) and opts[:cpu] < 1 -> {:error, :bad_cpu}
      is_integer(opts[:mem_gb]) and opts[:mem_gb] < 1 -> {:error, :bad_mem}
      true -> :ok
    end
  end

  defp update(m, opts) do
    m
    |> maybe_put("cpuCount", opts[:cpu])
    |> maybe_put("memoryBytes", opts[:mem_gb] && opts[:mem_gb] * @gb)
  end

  defp maybe_put(m, _key, nil), do: m
  defp maybe_put(m, key, val), do: Map.put(m, key, val)

  defp refute_running(name), do: if(Pidfile.running?(name), do: {:error, :running}, else: :ok)
  defp usage, do: {:error, 2, "usage: vzbeam set <name> [--cpu N] [--mem-gb M]\n"}

  defp error(_n, {:error, :no_such_bundle}), do: {:error, 1, "set: no such bundle\n"}
  defp error(name, {:error, :running}), do: {:error, 1, ["set: ", name, " is running; stop it first\n"]}
  defp error(_n, {:error, :bad_cpu}), do: {:error, 2, "set: --cpu must be >= 1\n"}
  defp error(_n, {:error, :bad_mem}), do: {:error, 2, "set: --mem-gb must be >= 1\n"}
  defp error(_n, {:error, reason}), do: {:error, 1, ["set failed: ", inspect(reason), "\n"]}
end
