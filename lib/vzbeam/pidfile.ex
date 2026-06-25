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

  @spec write(String.t(), integer | binary) :: :ok | {:error, atom}
  def write(name, os_pid) do
    pid = to_pid_integer(os_pid)

    with {:ok, started} <- process_start(pid),
         :ok <-
           VzBeam.AtomicFile.write(
             path(name),
             Jason.encode!(%{"pid" => pid, "startedAt" => started, "bundle" => name})
           ) do
      :ok
    else
      :error -> {:error, :process_not_found}
      {:error, reason} -> {:error, reason}
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

  @spec reap(String.t(), integer, pos_integer) :: :stopped | :timeout
  def reap(name, deadline, poll_ms) do
    cond do
      not running?(name) -> :stopped
      System.monotonic_time(:millisecond) >= deadline -> :timeout
      true -> Process.sleep(poll_ms); reap(name, deadline, poll_ms)
    end
  end

  defp to_pid_integer(p) when is_integer(p), do: p
  defp to_pid_integer(p) when is_binary(p), do: String.to_integer(p)
end
