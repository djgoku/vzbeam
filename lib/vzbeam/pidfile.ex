defmodule VzBeam.Pidfile do
  @moduledoc "vm.pid runtime state with PID-reuse-safe liveness."
  alias VzBeam.Home

  @spec path(String.t()) :: Path.t()
  def path(name), do: Path.join(Home.bundle_dir(name), "vm.pid")

  @spec process_start(String.t() | integer) :: {:ok, String.t()} | :error
  def process_start(os_pid) do
    case System.cmd("ps", ["-o", "lstart=", "-p", to_string(os_pid)], stderr_to_stdout: true) do
      {out, 0} ->
        case String.trim(out) do
          "" -> :error
          start -> {:ok, start}
        end

      {_, _} ->
        :error
    end
  end

  @spec write(String.t(), String.t() | integer) :: :ok | {:error, term}
  def write(name, os_pid) do
    with {:ok, started} <- process_start(os_pid) do
      atomic_write(path(name), Jason.encode!(%{
        "pid" => to_string(os_pid),
        "startedAt" => started,
        "bundle" => name
      }))
    else
      :error -> {:error, :process_not_found}
    end
  end

  @spec read(String.t()) :: {:ok, map} | {:error, term}
  def read(name) do
    with {:ok, body} <- File.read(path(name)), do: Jason.decode(body)
  end

  @spec running?(String.t()) :: boolean
  def running?(name) do
    with {:ok, %{"pid" => pid, "startedAt" => started}} <- read(name),
         {:ok, ^started} <- process_start(pid) do
      true
    else
      _ -> false
    end
  end

  defp atomic_write(target, body) do
    tmp = target <> ".tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp, body), :ok <- File.rename(tmp, target) do
      :ok
    else
      err -> File.rm(tmp); err
    end
  end
end
