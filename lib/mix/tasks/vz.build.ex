defmodule Mix.Tasks.Vz.Build do
  use Mix.Task
  @shortdoc "Build, ad-hoc-sign (virtualization entitlement), and install the Swift vz sidecar"
  @swift "swift"

  @impl true
  def run(_argv) do
    Mix.Task.run("compile")
    product = build()
    sign(product)
    dest = install(product)
    Mix.shell().info("vz installed -> #{dest}")
  end

  defp build do
    # Streaming build: output goes straight to the console as it compiles.
    {_, status} =
      System.cmd("swift", ["build", "-c", "release", "--package-path", @swift],
        stderr_to_stdout: true, into: IO.stream(:stdio, :line))

    if status != 0, do: Mix.raise("`swift build` failed (exit #{status}); see the build output above.")

    {bin, _} = sh!("swift", ["build", "-c", "release", "--show-bin-path", "--package-path", @swift])
    Path.join(String.trim(bin), "vz")
  end

  defp sign(product) do
    ent = Path.join(@swift, "vz.entitlements")
    sh!("codesign", ["--force", "--sign", "-", "--entitlements", ent, product])
  end

  defp install(product) do
    bin = Path.join(VzBeam.Home.root(), "bin")
    File.mkdir_p!(bin)
    dest = Path.join(bin, "vz")
    File.cp!(product, dest)
    File.chmod!(dest, 0o755)
    dest
  end

  # Run a captured command; on non-zero exit, fail the task with the command + status + output
  # (instead of crashing on a `{_, 0} = ...` match, which loses the context).
  defp sh!(cmd, args) do
    {out, status} = System.cmd(cmd, args, stderr_to_stdout: true)

    if status != 0 do
      Mix.raise("`#{cmd} #{Enum.join(args, " ")}` failed (exit #{status}):\n#{String.trim(out)}")
    end

    {out, status}
  end
end
