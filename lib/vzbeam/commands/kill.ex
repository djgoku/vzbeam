defmodule VzBeam.Commands.Kill do
  @moduledoc "kill <name> — force power-off: SIGTERM to the vz run pid (sidecar traps), SIGKILL last resort. Never pkill."
  alias VzBeam.Pidfile

  @reap_ms 20_000
  @poll_ms 200

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run(args), do: run(args, default_deps())

  def run([name], deps) do
    case Pidfile.read(name) do
      {:ok, %{"pid" => pid}} ->
        # Re-confirm liveness (start-time match) immediately before signaling (no PID-reuse hit).
        if Pidfile.running?(name) do
          deps.signal.("-TERM", pid)
          deadline = System.monotonic_time(:millisecond) + Map.get(deps, :reap_ms, @reap_ms)

          case Pidfile.reap(name, deadline, @poll_ms) do
            :stopped ->
              File.rm(Pidfile.path(name)); {:ok, ["killed ", name, "\n"]}

            :timeout ->
              deps.signal.("-KILL", pid); File.rm(Pidfile.path(name)); {:ok, ["killed ", name, " (SIGKILL)\n"]}
          end
        else
          File.rm(Pidfile.path(name)); {:ok, [name, " was not running (cleaned stale vm.pid)\n"]}
        end

      _ ->
        {:error, 1, ["no such running VM: ", name, "\n"]}
    end
  end

  def run(_, _), do: {:error, 2, "usage: vzbeam kill <name>\n"}

  @doc false
  def default_deps do
    %{signal: fn sig, pid -> System.cmd("kill", [sig, to_string(pid)], stderr_to_stdout: true) end,
      reap_ms: @reap_ms}
  end
end
