defmodule VzBeam.Sidecar do
  @moduledoc "Locate, version-check, and invoke the Swift `vz` sidecar."
  alias VzBeam.{Home, Protocol, Shell}

  @protocol_version 1
  @line_max 1_048_576
  @terminals %{"image-info" => ["image"], "restore" => ["restored"],
               "reid" => ["reid"], "--version" => ["version"]}

  @spec locate() :: {:ok, Path.t()} | {:error, :not_found}
  def locate do
    [System.get_env("VZBEAM_VZ"), Path.join([Home.root(), "bin", "vz"]),
     priv_vz(:code.priv_dir(:vzbeam)), alongside_cli(), System.find_executable("vz")]
    |> Enum.find(&usable?/1)
    |> case do
      nil -> {:error, :not_found}
      path -> debug(path); {:ok, path}
    end
  end

  # Guard :code.priv_dir/1 — it returns {:error, :bad_name} when the app isn't
  # loaded / has no priv dir, which would crash Path.join/2. Only a Burrito
  # release actually bundles priv/vz; in dev/escript this yields a path that
  # doesn't exist (usable?/1 skips it).
  @doc false
  @spec priv_vz({:error, term} | charlist | binary) :: nil | Path.t()
  def priv_vz({:error, _}), do: nil
  def priv_vz(dir), do: Path.join(to_string(dir), "vz")

  # Troubleshooting aid: a stale $VZBEAM_HOME/bin/vz can shadow the bundle, and
  # the --version check only catches wire-protocol drift — so make the resolved
  # path observable.
  defp debug(path) do
    if System.get_env("VZBEAM_DEBUG") not in [nil, ""],
      do: IO.puts(:stderr, "vzbeam: using sidecar #{path}")
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
    with {:ok, path} <- locate(), do: call_at(path, subcommand, args, runner)
  end

  # Invoke an already-located sidecar — skips a second locate/0 when the caller
  # already holds the path (e.g. `run` locates once, then version-checks it).
  defp call_at(path, subcommand, args, runner) do
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

  @spec check_version(Path.t(), fun) :: :ok | {:error, term}
  def check_version(path, runner \\ &System.cmd/3) do
    with {:ok, events} <- call_at(path, "--version", [], runner),
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

  @spec stream(String.t(), [String.t()], (Protocol.event() -> any)) :: {:ok, [Protocol.event()]} | {:error, term}
  def stream(subcommand, args, on_event \\ fn _ -> :ok end) do
    with {:ok, path} <- locate() do
      stderr = Path.join(System.tmp_dir!(), "vz-stderr-#{System.unique_integer([:positive])}")
      cmd = "#{Shell.join([path, subcommand | args])} 2>#{Shell.quote_arg(stderr)}"
      port = Port.open({:spawn_executable, "/bin/sh"}, [:binary, :exit_status, {:line, @line_max}, args: ["-c", cmd]])

      {events, status, corrupt?} = collect_stream(port, on_event, [], false)
      tail = stderr_tail(stderr)
      File.rm(stderr)
      resolve(events, subcommand, status, tail, corrupt?)
    end
  end

  @spec restore(map, (Protocol.event() -> any)) :: {:ok, map} | {:error, term}
  def restore(opts, on_event \\ fn _ -> :ok end) do
    args = ["--ipsw", opts.ipsw, "--disk", opts.disk, "--aux", opts.aux,
            "--disk-size", to_string(opts.disk_size),
            "--cpu", to_string(opts.cpu), "--mem", to_string(opts.mem)]

    with {:ok, events} <- stream("restore", args, on_event),
         {:event, "restored", m} <- find(events, "restored") do
      {:ok, %{machine_identifier: m["machineIdentifier"], hardware_model: m["hardwareModel"],
              mac_address: m["macAddress"], version: m["version"], build: m["build"]}}
    end
  end

  defp collect_stream(port, on_event, acc, corrupt?) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Protocol.decode_line(line) do
          {:event, _, _} = ev -> on_event.(ev); collect_stream(port, on_event, [ev | acc], corrupt?)
          {:error, _} -> collect_stream(port, on_event, acc, true)
        end

      # A partial line — an oversize (>1 MiB) line or unterminated trailing bytes.
      # The real vz newline-terminates every event (Wire.emit), so this is a
      # truncated/corrupt stream, not a normal delivery.
      {^port, {:data, {:noeol, _partial}}} ->
        collect_stream(port, on_event, acc, true)

      {^port, {:exit_status, status}} ->
        {Enum.reverse(acc), status, corrupt?}
    end
  end

  # Precedence: an explicit sidecar `error` event dominates; then a non-zero exit
  # (with its stderr tail); then stream corruption — a malformed or partial line
  # makes even a present terminal untrustworthy, so don't report success; then the
  # terminal; else no terminal at all.
  defp resolve(events, subcommand, status, stderr_tail, corrupt?) do
    error = Enum.find(events, &match?({:event, "error", _}, &1))
    terminal = Enum.find(events, fn {:event, t, _} -> t in Map.get(@terminals, subcommand, []) end)

    cond do
      error ->
        {:event, "error", m} = error
        {:error, {:vz, m["domain"], m["code"], m["message"]}}

      status != 0 ->
        {:error, {:exit, status, stderr_tail}}

      corrupt? ->
        {:error, {:protocol, :corrupt_stream}}

      terminal ->
        {:ok, events}

      true ->
        {:error, :no_terminal}
    end
  end

  defp stderr_tail(path) do
    case File.read(path) do
      {:ok, body} -> body |> String.slice(-4096, 4096) |> to_string()
      _ -> ""
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
