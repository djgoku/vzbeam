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
    {_, 0} = System.cmd("swift", ["build", "-c", "release", "--package-path", @swift],
                        stderr_to_stdout: true, into: IO.stream(:stdio, :line))
    {bin, 0} = System.cmd("swift", ["build", "-c", "release", "--show-bin-path", "--package-path", @swift])
    Path.join(String.trim(bin), "vz")
  end

  defp sign(product) do
    ent = Path.join(@swift, "vz.entitlements")
    {_, 0} = System.cmd("codesign", ["--force", "--sign", "-", "--entitlements", ent, product],
                        stderr_to_stdout: true)
  end

  defp install(product) do
    bin = Path.join(VzBeam.Home.root(), "bin")
    File.mkdir_p!(bin)
    dest = Path.join(bin, "vz")
    File.cp!(product, dest)
    File.chmod!(dest, 0o755)
    dest
  end
end
