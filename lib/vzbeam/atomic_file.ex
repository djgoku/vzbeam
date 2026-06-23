defmodule VzBeam.AtomicFile do
  @moduledoc "Atomic write: mkdir_p the parent, write to a temp file, rename into place."

  @spec write(Path.t(), iodata) :: :ok | {:error, term}
  def write(target, body) do
    with :ok <- File.mkdir_p(Path.dirname(target)) do
      tmp = "#{target}.tmp.#{System.unique_integer([:positive])}"

      with :ok <- File.write(tmp, body),
           :ok <- File.rename(tmp, target) do
        :ok
      else
        err -> File.rm(tmp); err
      end
    end
  end
end
