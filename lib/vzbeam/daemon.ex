defmodule VzBeam.Daemon do
  @moduledoc "Detached spawn: nohup the child, redirect stdio to a log, capture the launch pid. The child reparents to launchd and survives the BEAM exit; nohup makes it ignore SIGHUP."
  alias VzBeam.Shell

  @spec spawn_detached([String.t()], Path.t(), (String.t(), [String.t()], keyword -> {String.t(), non_neg_integer})) ::
          {:ok, pos_integer} | {:error, term}
  def spawn_detached(argv, log_path, runner \\ &System.cmd/3) do
    nohup = System.find_executable("nohup") || "/usr/bin/nohup"
    cmd = "#{Shell.quote_arg(nohup)} #{Shell.join(argv)} >#{Shell.quote_arg(log_path)} 2>&1 & echo $!"

    case runner.("sh", ["-c", cmd], []) do
      {out, 0} ->
        case Integer.parse(String.trim(out)) do
          {pid, _} -> {:ok, pid}
          :error -> {:error, {:bad_pid, String.trim(out)}}
        end

      {out, status} ->
        {:error, {:spawn_failed, status, String.trim(out)}}
    end
  end
end
