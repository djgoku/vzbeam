defmodule VzBeam.Sidecar.Build do
  @moduledoc "Build + ad-hoc-sign (virtualization entitlement) the Swift `vz` sidecar."

  @swift "swift"

  @doc """
  Compile `swift/` in release mode and ad-hoc-sign the `vz` product with the
  virtualization entitlement (swift drops it on every relink, so re-sign every
  build). Returns the signed product path. `runner` matches `System.cmd/3`.
  """
  @spec build_and_sign(Path.t(), function()) :: {:ok, Path.t()} | {:error, String.t()}
  def build_and_sign(swift_dir \\ @swift, runner \\ &System.cmd/3) do
    with :ok <- compile(swift_dir, runner),
         {:ok, product} <- product_path(swift_dir, runner),
         :ok <- sign(swift_dir, product, runner) do
      {:ok, product}
    end
  end

  defp compile(swift_dir, runner) do
    {out, status} =
      runner.("swift", ["build", "-c", "release", "--package-path", swift_dir], stderr_to_stdout: true)

    if status == 0, do: :ok, else: {:error, "`swift build` failed (exit #{status}):\n#{out}"}
  end

  defp product_path(swift_dir, runner) do
    {out, status} =
      runner.("swift", ["build", "-c", "release", "--show-bin-path", "--package-path", swift_dir],
        stderr_to_stdout: true)

    if status == 0,
      do: {:ok, Path.join(String.trim(to_string(out)), "vz")},
      else: {:error, "`swift build --show-bin-path` failed (exit #{status}):\n#{out}"}
  end

  defp sign(swift_dir, product, runner) do
    ent = Path.join(swift_dir, "vz.entitlements")

    {out, status} =
      runner.("codesign", ["--force", "--sign", "-", "--entitlements", ent, product],
        stderr_to_stdout: true)

    if status == 0, do: :ok, else: {:error, "codesign failed (exit #{status}):\n#{out}"}
  end
end
