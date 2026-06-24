defmodule VzBeam.Shell do
  @moduledoc "POSIX single-quote escaping for building `sh -c` command strings."

  @spec quote_arg(term) :: String.t()
  def quote_arg(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"

  @spec join([term]) :: String.t()
  def join(argv), do: Enum.map_join(argv, " ", &quote_arg/1)
end
