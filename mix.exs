defmodule VzBeam.MixProject do
  use Mix.Project

  def project do
    [
      app: :vzbeam,
      version: "0.1.0",
      elixir: "~> 1.17",
      escript: [main_module: VzBeam.CLI],
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps, do: [{:jason, "~> 1.4"}]
end
