defmodule VzBeam.Application do
  @moduledoc false
  use Application

  # In a Burrito-wrapped release this process IS the CLI: read argv from the Zig
  # wrapper, run the command, halt. Everywhere else (mix test, iex -S mix, the
  # escript) get_bin_path/0 reports :not_in_burrito, so we stay an inert (empty)
  # supervisor and let VzBeam.CLI.main/1 drive instead.
  @impl true
  def start(_type, _args) do
    if cli_mode?() do
      VzBeam.CLI.main(Burrito.Util.Args.argv())
      System.halt(0)
    else
      Supervisor.start_link([], strategy: :one_for_one, name: VzBeam.Supervisor)
    end
  end

  @doc false
  @spec cli_mode?() :: boolean
  def cli_mode?, do: Burrito.Util.Args.get_bin_path() != :not_in_burrito
end
