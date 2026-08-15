defmodule VzBeam.MixProject do
  use Mix.Project

  def project do
    [
      app: :vzbeam,
      version: "0.3.1",
      elixir: "~> 1.17",
      escript: [main_module: VzBeam.CLI, app: nil],
      releases: releases(),
      deps: deps()
    ]
  end

  def application, do: [mod: {VzBeam.Application, []}, extra_applications: [:logger]]

  defp releases do
    [
      vzbeam: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          # custom_erts: reuse the host (mise-installed) OTP instead of
          # downloading Burrito's universal macOS build. arm64-only output.
          targets: [
            macos_silicon: [
              os: :darwin,
              cpu: :aarch64,
              custom_erts: to_string(:code.root_dir())
            ]
          ],
          extra_steps: [patch: [post: [VzBeam.Release.StageSidecar]]]
        ]
      ]
    ]
  end

  defp deps, do: [{:jason, "~> 1.4"}, {:burrito, "~> 1.6"}]
end
