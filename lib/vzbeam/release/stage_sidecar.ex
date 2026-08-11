defmodule VzBeam.Release.StageSidecar do
  @moduledoc false
  @behaviour Burrito.Builder.Step

  # Burrito patch-phase step: build + ad-hoc-sign the Swift `vz` and drop it into
  # the release payload's priv/ so :code.priv_dir(:vzbeam) resolves it at runtime.
  # work_dir is the directory Burrito archives.
  @impl true
  def execute(context), do: stage(context, &VzBeam.Sidecar.Build.build_and_sign/0)

  @doc false
  def stage(%{work_dir: work_dir, mix_release: %{version: version}} = context, build_fun) do
    product =
      case build_fun.() do
        {:ok, p} -> p
        {:error, m} -> raise "vz sidecar staging failed: #{m}"
      end

    # --overwrite keeps lib dirs of previously built versions, so a glob can
    # match more than one; address the current release version exactly.
    app_dir = Path.join(work_dir, "lib/vzbeam-#{version}")

    File.dir?(app_dir) ||
      raise "vz sidecar staging failed: missing app dir lib/vzbeam-#{version} in #{work_dir}"
    dest = Path.join([app_dir, "priv", "vz"])
    File.mkdir_p!(Path.dirname(dest))
    File.cp!(product, dest)
    File.chmod!(dest, 0o755)
    IO.puts("burrito: staged signed vz -> #{dest} (sha256=#{sha256(dest)})")
    context
  end

  defp sha256(path),
    do: :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)
end
