defmodule VzBeam.Disk do
  @moduledoc "Sparse disk.img helpers: create, grow, inspect size. Never shrinks."

  @gb 1024 * 1024 * 1024

  @doc "Create a sparse file whose apparent size is `size` bytes."
  @spec create_sparse(Path.t(), pos_integer) :: :ok | {:error, term}
  def create_sparse(path, size) do
    File.open(path, [:write, :raw], fn fd -> :file.pwrite(fd, size - 1, <<0>>) end)
    |> unwrap()
  end

  @doc """
  Grow an existing sparse image to `want` bytes (no-op if already that size).
  Shrinking would truncate live APFS data, so a smaller target is refused
  with `{:error, {:shrink, current_size}}`.
  """
  @spec grow(Path.t(), pos_integer) :: :ok | {:error, term}
  def grow(path, want) do
    with {:ok, %{size: have}} <- File.stat(path) do
      cond do
        want < have ->
          {:error, {:shrink, have}}

        want == have ->
          :ok

        true ->
          # :read keeps open from truncating the existing contents.
          File.open(path, [:read, :write, :raw], fn fd -> :file.pwrite(fd, want - 1, <<0>>) end)
          |> unwrap()
      end
    end
  end

  @doc "Apparent size of the image in bytes, or nil if it doesn't exist."
  @spec size(Path.t()) :: non_neg_integer | nil
  def size(path) do
    case File.stat(path) do
      {:ok, %{size: s}} -> s
      _ -> nil
    end
  end

  @doc ~s(Render bytes as whole gigabytes \("64G"\); nil renders as "-".)
  @spec gb(non_neg_integer | nil) :: String.t()
  def gb(nil), do: "-"
  def gb(bytes), do: "#{trunc(bytes / @gb)}G"

  defp unwrap({:ok, :ok}), do: :ok
  defp unwrap({:ok, err}), do: err
  defp unwrap(err), do: err
end
