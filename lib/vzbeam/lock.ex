defmodule VzBeam.Lock do
  @moduledoc "Host-wide advisory lock at $VZBEAM_HOME/run.lock: atomic create-with-content via make_link, start-time-matched liveness, steal only a confirmed-dead holder."
  alias VzBeam.{Home, Pidfile}

  @poll_ms 5

  @spec path() :: Path.t()
  def path, do: Path.join(Home.root(), "run.lock")

  @spec with_lock((-> r), pos_integer) :: {:ok, r} | {:error, :lock_timeout | :lock_corrupt} when r: term
  def with_lock(fun, timeout_ms \\ 10_000) do
    case acquire(timeout_ms) do
      :ok ->
        try do
          {:ok, fun.()}
        after
          release()
        end

      {:error, _} = err ->
        err
    end
  end

  @spec acquire(pos_integer) :: :ok | {:error, :lock_timeout | :lock_corrupt}
  def acquire(timeout_ms \\ 10_000) do
    File.mkdir_p(Home.root())

    case Pidfile.process_start(System.pid()) do
      {:ok, started} ->
        record = Jason.encode!(%{"pid" => System.pid(), "startedAt" => started})
        deadline = System.monotonic_time(:millisecond) + timeout_ms
        loop(record, deadline)

      :error ->
        {:error, :lock_corrupt}
    end
  end

  @spec release() :: :ok
  def release do
    File.rm(path())
    :ok
  end

  defp loop(record, deadline) do
    lk = path()
    tmp = "#{lk}.#{System.pid()}.#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp, record)

    outcome =
      case :file.make_link(tmp, lk) do
        :ok -> :acquired
        {:error, :eexist} -> holder_status(lk)
        {:error, :enoent} -> :absent
      end

    File.rm(tmp)

    case outcome do
      :acquired -> :ok
      :dead -> File.rm(lk); loop(record, deadline)
      :absent -> loop(record, deadline)
      status -> wait(record, deadline, reason(status))
    end
  end

  defp wait(record, deadline, reason) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, reason}
    else
      Process.sleep(@poll_ms)
      loop(record, deadline)
    end
  end

  defp reason(:corrupt), do: :lock_corrupt
  defp reason(_), do: :lock_timeout

  # :dead (steal confirmed-dead holder) | :absent (lock vanished, just retry) | :alive (wait) | :corrupt
  defp holder_status(lk) do
    with {:ok, body} <- File.read(lk),
         {:ok, %{"pid" => pid, "startedAt" => started}} <- Jason.decode(body) do
      if Pidfile.process_start(pid) == {:ok, started}, do: :alive, else: :dead
    else
      {:error, :enoent} -> :absent
      _ -> :corrupt
    end
  end
end
