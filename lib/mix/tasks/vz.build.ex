defmodule Mix.Tasks.Vz.Build do
  use Mix.Task
  @shortdoc "Build, ad-hoc-sign (virtualization entitlement), and install the Swift vz sidecar"

  @impl true
  def run(_argv) do
    Mix.Task.run("compile")

    case VzBeam.Sidecar.Build.build_and_sign() do
      {:ok, product} ->
        dest = install(product)
        Mix.shell().info("vz installed -> #{dest}")

      {:error, message} ->
        Mix.raise(message)
    end
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
