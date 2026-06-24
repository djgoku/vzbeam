defmodule VzBeam.Sidecar do
  @moduledoc "Locate, version-check, and invoke the Swift `vz` sidecar."
  alias VzBeam.{Home, Protocol}

  @protocol_version 1
  @terminals %{"image-info" => ["image"], "restore" => ["restored"],
               "reid" => ["reid"], "--version" => ["version"]}

  @spec locate() :: {:ok, Path.t()} | {:error, :not_found}
  def locate do
    [System.get_env("VZBEAM_VZ"), Path.join([Home.root(), "bin", "vz"]),
     alongside_cli(), System.find_executable("vz")]
    |> Enum.find(&usable?/1)
    |> case do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  defp usable?(p) when is_binary(p) and p != "", do: File.regular?(p)
  defp usable?(_), do: false

  defp alongside_cli do
    Path.join(Path.dirname(Path.expand(to_string(:escript.script_name()))), "vz")
  rescue
    _ -> nil
  end

  @spec call(String.t(), [String.t()], fun) :: {:ok, [Protocol.event()]} | {:error, term}
  def call(subcommand, args, runner \\ &System.cmd/3) do
    with {:ok, path} <- locate() do
      {out, status} = runner.(path, [subcommand | args], [])
      lines = String.split(out, "\n", trim: true)
      final_newline? = out == "" or String.ends_with?(out, "\n")

      result = Protocol.collect(lines, Map.get(@terminals, subcommand, []), final_newline?)

      cond do
        match?({:error, {:vz, _, _, _}}, result) -> result
        status != 0 -> {:error, {:exit, status}}
        true ->
          case result do
            {:ok, events, _terminal} -> {:ok, events}
            {:error, _} = err -> err
          end
      end
    end
  end

  @spec check_version(fun) :: :ok | {:error, term}
  def check_version(runner \\ &System.cmd/3) do
    with {:ok, events} <- call("--version", [], runner),
         {:event, "version", m} <- find(events, "version") do
      if m["protocol"] == @protocol_version,
        do: :ok,
        else: {:error, {:incompatible, m["protocol"], @protocol_version}}
    end
  end

  @spec image_info(String.t(), fun) :: {:ok, map} | {:error, term}
  def image_info(spec, runner \\ &System.cmd/3) do
    with {:ok, events} <- call("image-info", [spec], runner),
         {:event, "image", m} <- find(events, "image") do
      {:ok, %{version: m["version"], build: m["build"], url: m["url"], source: m["source"]}}
    end
  end

  @spec reid(fun) :: {:ok, map} | {:error, term}
  def reid(runner \\ &System.cmd/3) do
    with {:ok, events} <- call("reid", [], runner),
         {:event, "reid", m} <- find(events, "reid") do
      {:ok, %{machine_identifier: m["machineIdentifier"], mac_address: m["macAddress"]}}
    end
  end

  @spec restore(map, fun) :: {:ok, map} | {:error, term}
  def restore(opts, runner \\ &System.cmd/3) do
    args = ["--ipsw", opts.ipsw, "--disk", opts.disk, "--aux", opts.aux,
            "--disk-size", to_string(opts.disk_size),
            "--cpu", to_string(opts.cpu), "--mem", to_string(opts.mem)]

    with {:ok, events} <- call("restore", args, runner),
         {:event, "restored", m} <- find(events, "restored") do
      {:ok, %{machine_identifier: m["machineIdentifier"], hardware_model: m["hardwareModel"],
              mac_address: m["macAddress"], version: m["version"], build: m["build"]}}
    end
  end

  defp find(events, type) do
    Enum.find(events, :missing, &match?({:event, ^type, _}, &1))
    |> case do
      :missing -> {:error, {:protocol, :missing, type}}
      ev -> ev
    end
  end
end
