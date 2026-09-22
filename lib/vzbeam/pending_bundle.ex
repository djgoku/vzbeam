defmodule VzBeam.PendingBundle do
  @moduledoc "PID/start-time-owned pending bundle creation under the host lock."
  alias VzBeam.{AtomicFile, Home, Lock, Pidfile}

  defstruct [:name, :path, :owner]

  @type t :: %__MODULE__{name: String.t(), path: Path.t(), owner: map}

  @spec claim(String.t(), map) :: {:ok, t} | {:error, term}
  def claim(name, deps \\ default_deps()) do
    pid = System.pid() |> String.to_integer()

    case deps.process_start.(pid) do
      {:ok, started} ->
        owner = %{"pid" => pid, "startedAt" => started}

        deps.with_lock.(fn -> claim_locked(name, owner, deps.process_start) end)
        |> normalize_claim()

      :error ->
        {:error, :process_not_found}
    end
  end

  @spec cleanup(t, ((-> term) -> {:ok, term} | {:error, term})) ::
          :ok | {:error, term}
  def cleanup(%__MODULE__{} = claim, with_lock \\ &Lock.with_lock/1) do
    with_lock.(fn -> cleanup_locked(claim) end)
    |> normalize_action()
  end

  @spec promote(t, ((-> term) -> {:ok, term} | {:error, term})) ::
          :ok | {:error, term}
  def promote(%__MODULE__{} = claim, with_lock \\ &Lock.with_lock/1) do
    with_lock.(fn -> promote_locked(claim) end)
    |> normalize_action()
  end

  defp claim_locked(name, owner, process_start) do
    path = Home.bundle_dir(name) <> ".pending"

    cond do
      path_present?(Home.bundle_dir(name)) ->
        {:error, :exists}

      not File.exists?(path) ->
        create_claim(name, path, owner)

      true ->
        case read_owner(path) do
          {:ok, %{"pid" => pid, "startedAt" => started}} ->
            if process_start.(pid) == {:ok, started} do
              {:error, :creation_in_progress}
            else
              reclaim(name, path, owner)
            end

          _ ->
            {:error, :pending_owner_unreadable}
        end
    end
  end

  defp reclaim(name, path, owner) do
    case File.rm_rf(path) do
      {:ok, _} -> create_claim(name, path, owner)
      {:error, reason, file} -> {:error, {:pending_cleanup, file, reason}}
    end
  end

  defp create_claim(name, path, owner) do
    with :ok <- File.mkdir_p(path),
         :ok <- AtomicFile.write(owner_path(path), Jason.encode!(owner)) do
      {:ok, %__MODULE__{name: name, path: path, owner: owner}}
    end
  end

  defp cleanup_locked(claim) do
    with :ok <- match_owner(claim) do
      case File.rm_rf(claim.path) do
        {:ok, _} -> :ok
        {:error, reason, file} -> {:error, {:pending_cleanup, file, reason}}
      end
    end
  end

  defp promote_locked(claim) do
    final = Home.bundle_dir(claim.name)

    with :ok <- match_owner(claim),
         :ok <- refute_final(claim.name),
         :ok <- rename(claim.path, final),
         :ok <- File.rm(owner_path(final)) do
      :ok
    end
  end

  defp refute_final(name),
    do: if(path_present?(Home.bundle_dir(name)), do: {:error, :exists}, else: :ok)

  defp path_present?(path), do: match?({:ok, _}, File.lstat(path))

  defp rename(from, to) do
    case File.rename(from, to) do
      :ok -> :ok
      {:error, reason} -> {:error, {:promote_failed, reason}}
    end
  end

  defp match_owner(%__MODULE__{path: path, owner: expected}) do
    case read_owner(path) do
      {:ok, ^expected} -> :ok
      _ -> {:error, :owner_mismatch}
    end
  end

  defp read_owner(path) do
    with {:ok, body} <- File.read(owner_path(path)),
         {:ok, %{"pid" => pid, "startedAt" => started} = owner}
         when is_integer(pid) and is_binary(started) <- Jason.decode(body) do
      {:ok, owner}
    else
      _ -> {:error, :pending_owner_unreadable}
    end
  end

  defp owner_path(path), do: Path.join(path, "install-owner.json")

  defp normalize_claim({:ok, {:ok, %__MODULE__{} = claim}}), do: {:ok, claim}
  defp normalize_claim({:ok, {:error, reason}}), do: {:error, reason}
  defp normalize_claim({:error, reason}), do: {:error, reason}

  defp normalize_action({:ok, :ok}), do: :ok
  defp normalize_action({:ok, {:error, reason}}), do: {:error, reason}
  defp normalize_action({:error, reason}), do: {:error, reason}

  defp default_deps do
    %{with_lock: &Lock.with_lock/1, process_start: &Pidfile.process_start/1}
  end
end
