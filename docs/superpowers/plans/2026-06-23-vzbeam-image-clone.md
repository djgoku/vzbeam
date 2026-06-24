# vzbeam Plan 2 — image + clone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `fetch` / `images` / `new` / `rm` verbs (IPSW cache + APFS CoW clone + restore) to the vzbeam Elixir engine, built against a fake `vz` sidecar.

**Architecture:** Three new plumbing modules — `Protocol` (pure JSON-lines decoder), `Sidecar` (locate/version/invoke the `vz` binary via an injectable runner), `Cache` (IPSW store + `index.json`) — plus four verb modules. The `cp -Rc` clone and `cp -c` cache ingest are real; the sidecar calls (`image-info`/`restore`/`reid`) are exercised via an injectable runner and a fake-`vz` shell script. Cleanups that touch the same modules land first.

**Tech Stack:** Elixir `~> 1.17` (OTP 29), `escript`, `Jason` (the only dependency). macOS host.

## Global Constraints

- **No new dependencies** — Jason only; transport is zero-dep (`System.cmd`, `Port` later). erlexec/muontrap deferred to Plan 3.
- **All file writes atomic** — via `VzBeam.AtomicFile` (temp-then-rename, `mkdir_p` parent).
- **JSON maps are string-keyed** (Jason default); unknown keys preserved on read-modify-write.
- **Verb return contract:** `run/1 :: {:ok, iodata} | {:error, non_neg_integer, iodata}`; usage errors use code `2`, runtime errors code `1`.
- **Testability:** external effects (sidecar calls, downloads, lease reads) are injectable fns/maps with real defaults — mirror the existing `read_leases` pattern. Tests are `async: false`, set `VZBEAM_HOME` to a unique tmp dir, and clean up in `on_exit`.
- **Green-bucket only:** no VM boot. `cp -Rc`/`cp -c`/sparse-disk creation are real; sidecar `restore`/`reid`/`image-info` are faked. A green `mix test` proves orchestration, not the hypervisor.
- **$VZBEAM_HOME** default `~/.local/share/vzbeam`; cache at `$VZBEAM_HOME/cache/ipsw/`.
- Spec: `docs/superpowers/specs/2026-06-23-vzbeam-plan2-image-clone.md`.

## File Structure

| File | Responsibility |
|---|---|
| `lib/vzbeam/atomic_file.ex` (new) | Atomic write (mkdir_p + temp + rename) |
| `lib/vzbeam/protocol.ex` (new) | Pure JSON-lines decode + `collect/3` |
| `lib/vzbeam/sidecar.ex` (new) | Locate / version-check / invoke `vz` |
| `lib/vzbeam/cache.ex` (new) | IPSW store + `index.json`; `ensure/2` |
| `lib/vzbeam/commands/{fetch,images,new,rm}.ex` (new) | Verbs |
| `lib/vzbeam/manifest.ex` | Use `AtomicFile` |
| `lib/vzbeam/pidfile.ex` | Use `AtomicFile`; `pid`→integer; normalize errors |
| `lib/vzbeam/leases.ex` | Add `read/0` |
| `lib/vzbeam/home.ex` | Filter `*.pending` from `bundles/0` + lookup |
| `lib/vzbeam/commands/{ip,ls}.ex` | Use `Leases.read/0`; `Ls.mem` → `is_number` |
| `lib/vzbeam/cli.ex` | Dispatch + `@usage` for the four verbs |
| `test/support/fake_vz` (new) | Fake sidecar script for integration tests |

---

## Task 1: `AtomicFile` + `Manifest` refactor

**Files:**
- Create: `lib/vzbeam/atomic_file.ex`, `test/atomic_file_test.exs`
- Modify: `lib/vzbeam/manifest.ex:18-32`

**Interfaces:**
- Produces: `VzBeam.AtomicFile.write(target :: Path.t(), body :: iodata) :: :ok | {:error, term}` — creates parent dirs, writes to a unique temp, renames into place, removes the temp on failure.

- [ ] **Step 1: Write the failing test**

```elixir
# test/atomic_file_test.exs
defmodule VzBeam.AtomicFileTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "vzbeam-af-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "creates parent dirs, writes the file, leaves no temp", %{dir: dir} do
    target = Path.join([dir, "a", "b", "config.json"])
    assert :ok = VzBeam.AtomicFile.write(target, "hello")
    assert File.read!(target) == "hello"
    assert File.ls!(Path.join([dir, "a", "b"])) == ["config.json"]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/atomic_file_test.exs`
Expected: FAIL — `VzBeam.AtomicFile.write/2 is undefined`.

- [ ] **Step 3: Write the module**

```elixir
# lib/vzbeam/atomic_file.ex
defmodule VzBeam.AtomicFile do
  @moduledoc "Atomic write: mkdir_p the parent, write to a temp file, rename into place."

  @spec write(Path.t(), iodata) :: :ok | {:error, term}
  def write(target, body) do
    tmp = "#{target}.tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, target) do
      :ok
    else
      err -> File.rm(tmp); err
    end
  end
end
```

- [ ] **Step 4: Refactor `Manifest.write/2` to use it**

```elixir
# lib/vzbeam/manifest.ex — replace write/2
  @spec write(String.t(), map) :: :ok | {:error, term}
  def write(name, map) when is_map(map) do
    stamped = Map.put(map, "schemaVersion", @schema_version)
    VzBeam.AtomicFile.write(path(name), Jason.encode!(stamped, pretty: true))
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/atomic_file_test.exs test/manifest_test.exs`
Expected: PASS (manifest round-trip, schemaVersion, unknown-key tests still green).

- [ ] **Step 6: Commit**

```bash
git add lib/vzbeam/atomic_file.ex test/atomic_file_test.exs lib/vzbeam/manifest.ex
git commit -m "refactor: extract VzBeam.AtomicFile; Manifest uses it"
```

---

## Task 2: `Pidfile` refactor (AtomicFile + integer pid + normalized errors)

**Files:**
- Modify: `lib/vzbeam/pidfile.ex:22-58`
- Modify: `test/pidfile_test.exs` (add an integer-storage assertion)

**Interfaces:**
- Consumes: `VzBeam.AtomicFile.write/2` (Task 1).
- Produces: `Pidfile.write(name, os_pid :: integer | binary) :: :ok | {:error, atom}` — stores `pid` as an **integer**; `running?/1`, `read/1`, `process_start/1` unchanged in shape.

- [ ] **Step 1: Write the failing test**

```elixir
# test/pidfile_test.exs — add inside the module
  test "stores pid as an integer" do
    :ok = VzBeam.Pidfile.write("vm", System.pid())
    {:ok, m} = VzBeam.Pidfile.read("vm")
    assert is_integer(m["pid"])
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/pidfile_test.exs`
Expected: FAIL — `pid` is currently a string (`is_integer/1` false).

- [ ] **Step 3: Rewrite `write/2` (and the private atomic write goes away)**

```elixir
# lib/vzbeam/pidfile.ex — replace write/2 and delete the private atomic_write/2
  @spec write(String.t(), integer | binary) :: :ok | {:error, atom}
  def write(name, os_pid) do
    pid = to_pid_integer(os_pid)

    with {:ok, started} <- process_start(pid),
         :ok <-
           VzBeam.AtomicFile.write(
             path(name),
             Jason.encode!(%{"pid" => pid, "startedAt" => started, "bundle" => name})
           ) do
      :ok
    else
      :error -> {:error, :process_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_pid_integer(p) when is_integer(p), do: p
  defp to_pid_integer(p) when is_binary(p), do: String.to_integer(p)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/pidfile_test.exs`
Expected: PASS (new integer test + the four existing tests — `running?` reads the integer pid via `process_start`).

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/pidfile.ex test/pidfile_test.exs
git commit -m "refactor: Pidfile uses AtomicFile, stores integer pid, normalized errors"
```

---

## Task 3: Lease-reader dedup + `Ls` numeric broadening

**Files:**
- Modify: `lib/vzbeam/leases.ex` (add `read/0`), `lib/vzbeam/commands/ip.ex:22-24`, `lib/vzbeam/commands/ls.ex:40-41,57-59`
- Modify: `test/leases_test.exs` (add a `read/0` test)

**Interfaces:**
- Produces: `VzBeam.Leases.read/0 :: String.t()` — reads `path/0`, returns `""` on any error.

- [ ] **Step 1: Write the failing test**

```elixir
# test/leases_test.exs — add inside the module
  test "read/0 returns \"\" when the leases file is absent" do
    # default path won't exist in CI sandbox; must not raise
    assert is_binary(VzBeam.Leases.read())
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/leases_test.exs`
Expected: FAIL — `VzBeam.Leases.read/0 is undefined`.

- [ ] **Step 3: Add `Leases.read/0` and rewire the verbs**

```elixir
# lib/vzbeam/leases.ex — add
  @spec read() :: String.t()
  def read do
    case File.read(path()) do
      {:ok, content} -> content
      _ -> ""
    end
  end
```

```elixir
# lib/vzbeam/commands/ip.ex — replace the private read_leases/0 + the run/1 default
  def run(args), do: run(args, &VzBeam.Leases.read/0)
  # (delete the private defp read_leases/0)
```

```elixir
# lib/vzbeam/commands/ls.ex — replace the private read_leases/0 + the run/1 default, and broaden mem/1
  def run(args), do: run(args, &VzBeam.Leases.read/0)
  # (delete the private defp read_leases/0)

  defp mem(bytes) when is_number(bytes), do: "#{trunc(bytes / (1024 * 1024 * 1024))}G"
  defp mem(_), do: "-"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/leases_test.exs test/commands/ip_test.exs test/commands/ls_test.exs`
Expected: PASS (ip/ls still inject `fn -> ... end`; the default is now `&Leases.read/0`).

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/leases.ex lib/vzbeam/commands/ip.ex lib/vzbeam/commands/ls.ex test/leases_test.exs
git commit -m "refactor: shared Leases.read/0; Ls.mem handles any number"
```

---

## Task 4: `Home` ignores `*.pending`

**Files:**
- Modify: `lib/vzbeam/home.ex:16-27`
- Modify: `test/home_test.exs` (add a `.pending` exclusion test)

**Interfaces:**
- Produces: `Home.bundles/0` excludes any entry whose name ends in `.pending`; `Home.exists?(name) :: boolean` (a real, non-pending bundle with a manifest).

- [ ] **Step 1: Write the failing test**

```elixir
# test/home_test.exs — add inside the module
  test "bundles excludes *.pending dirs" do
    home = Path.join(System.tmp_dir!(), "vzbeam-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "base"))
    File.write!(Path.join([home, "base", "config.json"]), "{}")
    File.mkdir_p!(Path.join(home, "half.pending"))
    File.write!(Path.join([home, "half.pending", "config.json"]), "{}")
    System.put_env("VZBEAM_HOME", home)
    assert VzBeam.Home.bundles() == ["base"]
  after
    System.delete_env("VZBEAM_HOME")
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/home_test.exs`
Expected: FAIL — `bundles/0` currently returns `["base", "half.pending"]`.

- [ ] **Step 3: Filter `*.pending` in `bundles/0`; add `exists?/1`**

```elixir
# lib/vzbeam/home.ex — replace bundles/0 and add exists?/1
  @spec bundles() :: [String.t()]
  def bundles do
    case File.ls(root()) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&String.ends_with?(&1, ".pending"))
        |> Enum.filter(&File.regular?(Path.join([root(), &1, "config.json"])))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @spec exists?(String.t()) :: boolean
  def exists?(name) do
    not String.ends_with?(name, ".pending") and
      File.regular?(Path.join([root(), name, "config.json"]))
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/home_test.exs`
Expected: PASS (new exclusion test + the existing `bundles` tests).

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/home.ex test/home_test.exs
git commit -m "fix: Home ignores *.pending (crash-partial clones never appear as bundles)"
```

---

## Task 5: `VzBeam.Protocol` — JSON-lines decoder

**Files:**
- Create: `lib/vzbeam/protocol.ex`, `test/protocol_test.exs`

**Interfaces:**
- Produces:
  - `decode_line(binary) :: {:event, type :: String.t(), map} | {:error, :bad_json | :missing_type | :oversize}`
  - `collect(lines :: [binary], terminal_types :: [String.t()], final_newline? :: boolean) :: {:ok, [event], terminal :: {String.t(), map}} | {:error, {:vz, domain, code, message} | :no_terminal | :unterminated | :oversize | :bad_json}`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/protocol_test.exs
defmodule VzBeam.ProtocolTest do
  use ExUnit.Case, async: true
  alias VzBeam.Protocol

  test "decode_line tags by type / flags bad json / missing type / oversize" do
    assert {:event, "image", %{"build" => "25F80"}} =
             Protocol.decode_line(~s({"type":"image","build":"25F80"}))
    assert {:error, :bad_json} = Protocol.decode_line("not json")
    assert {:error, :missing_type} = Protocol.decode_line(~s({"x":1}))
    assert {:error, :oversize} = Protocol.decode_line(String.duplicate("x", 1_048_577))
  end

  test "collect finds the terminal event" do
    lines = [~s({"type":"progress","fraction":0.5}), ~s({"type":"restored","build":"25F80"})]
    assert {:ok, _events, {:event, "restored", %{"build" => "25F80"}}} =
             Protocol.collect(lines, ["restored"], true)
  end

  test "collect: error event dominates even with a terminal present" do
    lines = [~s({"type":"restored","build":"X"}), ~s({"type":"error","domain":"VZ","code":6,"message":"boom"})]
    assert {:error, {:vz, "VZ", 6, "boom"}} = Protocol.collect(lines, ["restored"], true)
  end

  test "collect: no terminal -> :no_terminal; unterminated final line -> :unterminated" do
    assert {:error, :no_terminal} = Protocol.collect([~s({"type":"progress"})], ["restored"], true)
    assert {:error, :unterminated} = Protocol.collect([~s({"type":"restored"})], ["restored"], false)
  end

  test "collect: unknown types are ignored, never terminal" do
    assert {:error, :no_terminal} = Protocol.collect([~s({"type":"weird"})], ["restored"], true)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/protocol_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Write the module**

```elixir
# lib/vzbeam/protocol.ex
defmodule VzBeam.Protocol do
  @moduledoc "Pure decoder for the vz JSON-lines wire protocol (no I/O)."

  @max_line 1_048_576
  @type event :: {:event, String.t(), map}

  @spec decode_line(binary) :: event | {:error, :bad_json | :missing_type | :oversize}
  def decode_line(line) when byte_size(line) > @max_line, do: {:error, :oversize}

  def decode_line(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => type} = map} -> {:event, type, map}
      {:ok, _} -> {:error, :missing_type}
      {:error, _} -> {:error, :bad_json}
    end
  end

  @spec collect([binary], [String.t()], boolean) :: {:ok, [event], event} | {:error, term}
  def collect(lines, terminal_types, final_newline?) do
    with :ok <- check_terminated(lines, final_newline?),
         {:ok, events} <- decode_all(lines) do
      error = Enum.find(events, &match?({:event, "error", _}, &1))
      terminal = Enum.find(events, fn {:event, t, _} -> t in terminal_types end)

      cond do
        error ->
          {:event, "error", m} = error
          {:error, {:vz, m["domain"], m["code"], m["message"]}}

        terminal ->
          {:ok, events, terminal}

        true ->
          {:error, :no_terminal}
      end
    end
  end

  defp check_terminated([], _), do: :ok
  defp check_terminated(_lines, true), do: :ok
  defp check_terminated(_lines, false), do: {:error, :unterminated}

  defp decode_all(lines) do
    result =
      Enum.reduce_while(lines, [], fn line, acc ->
        case decode_line(line) do
          {:event, _, _} = ev -> {:cont, [ev | acc]}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:error, _} = err -> err
      acc -> {:ok, Enum.reverse(acc)}
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/protocol_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/protocol.ex test/protocol_test.exs
git commit -m "feat: VzBeam.Protocol JSON-lines decoder"
```

---

## Task 6: `VzBeam.Sidecar` — locate / version / invoke

**Files:**
- Create: `lib/vzbeam/sidecar.ex`, `test/sidecar_test.exs`, `test/support/fake_vz`

**Interfaces:**
- Consumes: `VzBeam.Protocol.collect/3` (Task 5), `VzBeam.Home.root/0`.
- Produces:
  - `locate/0 :: {:ok, Path.t()} | {:error, :not_found}`
  - `check_version(runner \\ &System.cmd/3) :: :ok | {:error, {:incompatible, got, want} | term}`
  - `call(subcommand :: String.t(), args :: [String.t()], runner) :: {:ok, [event]} | {:error, term}`
  - `image_info(spec, runner \\ ...) :: {:ok, %{version, build, url, source}}` (atom keys)
  - `reid(runner \\ ...) :: {:ok, %{machine_identifier, mac_address}}`
  - `restore(opts :: keyword|map, runner \\ ...) :: {:ok, %{machine_identifier, hardware_model, mac_address, version, build}}`
  - `runner` shape: `(path, [arg], opts) -> {output :: binary, status :: non_neg_integer}`

- [ ] **Step 1: Create the fake sidecar script**

```sh
# test/support/fake_vz   (chmod +x after creating)
#!/bin/sh
case "$1" in
  --version)   echo '{"type":"version","protocol":1}'; exit 0 ;;
  image-info)  echo '{"type":"image","version":"26.5.1","build":"25F80","url":"file:///x.ipsw","source":"latest"}'; exit 0 ;;
  reid)        echo '{"type":"reid","machineIdentifier":"NEW-ID","macAddress":"5e:11:22:33:44:55"}'; exit 0 ;;
  errorcase)   echo "log to stderr" 1>&2; echo '{"type":"error","domain":"VZErrorDomain","code":6,"message":"max VMs"}'; exit 3 ;;
  *)           echo "fake_vz: unknown $1" 1>&2; exit 2 ;;
esac
```

- [ ] **Step 2: Write the failing tests**

```elixir
# test/sidecar_test.exs
defmodule VzBeam.SidecarTest do
  use ExUnit.Case, async: false
  alias VzBeam.Sidecar

  @fake Path.expand("support/fake_vz", __DIR__)

  setup do
    File.chmod!(@fake, 0o755)
    System.put_env("VZBEAM_VZ", @fake)
    on_exit(fn -> System.delete_env("VZBEAM_VZ") end)
    :ok
  end

  test "locate finds the binary via VZBEAM_VZ" do
    assert {:ok, @fake} = Sidecar.locate()
  end

  test "locate errors when nothing resolves" do
    System.put_env("VZBEAM_VZ", "/no/such/vz")
    assert {:error, :not_found} = Sidecar.locate()
  end

  test "check_version accepts protocol 1 (real subprocess, default runner)" do
    assert :ok = Sidecar.check_version()
  end

  test "image_info parses the image event (injected runner)" do
    runner = fn _p, ["image-info", "latest"], _ ->
      {~s({"type":"image","version":"26.5.1","build":"25F80","url":"u","source":"latest"}\n), 0}
    end
    assert {:ok, %{version: "26.5.1", build: "25F80", source: "latest"}} =
             Sidecar.image_info("latest", runner)
  end

  test "reid parses the reid event via the real fake_vz" do
    assert {:ok, %{machine_identifier: "NEW-ID", mac_address: "5e:11:22:33:44:55"}} = Sidecar.reid()
  end

  test "an error event maps to a typed VZ error (real fake_vz, exit 3)" do
    assert {:error, {:vz, "VZErrorDomain", 6, "max VMs"}} = Sidecar.call("errorcase", [])
  end

  test "truncated output surfaces as :unterminated" do
    runner = fn _p, _a, _ -> {~s({"type":"image","build":"25F80"}), 0} end  # no trailing newline
    assert {:error, :unterminated} = Sidecar.image_info("latest", runner)
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mix test test/sidecar_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 4: Write the module**

```elixir
# lib/vzbeam/sidecar.ex
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

      case Protocol.collect(lines, Map.get(@terminals, subcommand, []), final_newline?) do
        {:ok, events, _terminal} -> {:ok, events}
        {:error, :no_terminal} when status != 0 -> {:error, {:exit, status}}
        {:error, _} = err -> err
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/sidecar_test.exs`
Expected: PASS (locate rungs, real-`fake_vz` version/reid/error, injected image_info, unterminated).

- [ ] **Step 6: Commit**

```bash
chmod +x test/support/fake_vz
git add lib/vzbeam/sidecar.ex test/sidecar_test.exs test/support/fake_vz
git commit -m "feat: VzBeam.Sidecar locate/version/invoke + fake_vz"
```

---

## Task 7: `VzBeam.Cache` — IPSW store + index

**Files:**
- Create: `lib/vzbeam/cache.ex`, `test/cache_test.exs`

**Interfaces:**
- Consumes: `AtomicFile.write/2` (Task 1), `Home.root/0`, `Sidecar.image_info/1` (Task 6, as the default `image_info` dep).
- Produces:
  - `dir/0`, `index_path/0`, `read_index/0 :: map`, `list/0 :: [map]`, `lookup(build) :: {:ok, map} | :error`
  - `ensure(spec :: String.t(), deps \\ default_deps()) :: {:ok, :fetched | :cached | :reconciled, entry :: map} | {:error, term}`
  - `deps :: %{image_info: (spec -> {:ok, %{version,build,url,source}}|{:error,_}), download: (url, dst -> :ok|{:error,_}), copy: (src, dst -> :ok|{:error,_})}`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/cache_test.exs
defmodule VzBeam.CacheTest do
  use ExUnit.Case, async: false
  alias VzBeam.Cache

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    {:ok, home: home}
  end

  defp deps(build \\ "25F80") do
    %{
      image_info: fn _ -> {:ok, %{version: "26.5.1", build: build, url: "file:///x", source: "local"}} end,
      copy: fn _src, dst -> File.mkdir_p!(Path.dirname(dst)); File.write(dst, "IPSWBYTES") end,
      download: fn _url, _dst -> {:error, :should_not_download} end
    }
  end

  test "ensure fetches, indexes, and is idempotent" do
    assert {:ok, :fetched, e} = Cache.ensure("/tmp/x.ipsw", deps())
    assert e["build"] == "25F80" and e["file"] == "25F80.ipsw"
    assert File.regular?(Path.join(Cache.dir(), "25F80.ipsw"))
    assert {:ok, :cached, _} = Cache.ensure("/tmp/x.ipsw", deps())
    assert [%{"build" => "25F80"}] = Cache.list()
  end

  test "ensure reconciles an orphaned final file into the index (finding #1)" do
    File.mkdir_p!(Cache.dir())
    File.write!(Path.join(Cache.dir(), "25F80.ipsw"), "ORPHAN")
    assert {:ok, :reconciled, e} = Cache.ensure("/tmp/x.ipsw", deps())
    assert e["build"] == "25F80"
    assert {:ok, _} = Cache.lookup("25F80")
  end

  test "ensure rejects an unsafe build token (finding #7)" do
    assert {:error, :bad_build_token} = Cache.ensure("/tmp/x.ipsw", deps("../evil"))
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/cache_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Write the module**

```elixir
# lib/vzbeam/cache.ex
defmodule VzBeam.Cache do
  @moduledoc "Cached restore images (IPSW) + index.json under $VZBEAM_HOME/cache/ipsw."
  alias VzBeam.{Home, AtomicFile}

  @spec dir() :: Path.t()
  def dir, do: Path.join([Home.root(), "cache", "ipsw"])

  @spec index_path() :: Path.t()
  def index_path, do: Path.join(dir(), "index.json")

  @spec read_index() :: map
  def read_index do
    with {:ok, body} <- File.read(index_path()),
         {:ok, %{} = m} <- Jason.decode(body) do
      m
    else
      _ -> %{"schemaVersion" => 1, "images" => %{}}
    end
  end

  @spec lookup(String.t()) :: {:ok, map} | :error
  def lookup(build) do
    case read_index()["images"][build] do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  @spec list() :: [map]
  def list, do: read_index()["images"] |> Map.values() |> Enum.sort_by(& &1["build"])

  @spec ensure(String.t(), map) :: {:ok, atom, map} | {:error, term}
  def ensure(spec, deps \\ default_deps()) do
    with {:ok, info} <- deps.image_info.(spec),
         :ok <- validate_build(info.build) do
      final = Path.join(dir(), "#{info.build}.ipsw")

      case lookup(info.build) do
        {:ok, entry} -> {:ok, :cached, entry}
        :error -> if File.regular?(final),
                    do: {:ok, :reconciled, put_index(info, final)},
                    else: acquire(spec, info, final, deps)
      end
    end
  end

  defp acquire(spec, info, final, deps) do
    File.mkdir_p!(dir())
    pending = "#{final}.#{System.unique_integer([:positive])}.pending"
    acquire = if spec == "latest", do: deps.download.(info.url, pending), else: deps.copy.(spec, pending)

    with :ok <- acquire,
         :ok <- size_sane(pending),
         :ok <- File.rename(pending, final) do
      {:ok, :fetched, put_index(info, final)}
    else
      err -> File.rm(pending); err
    end
  end

  defp put_index(info, final) do
    entry = %{"version" => info.version, "build" => info.build, "file" => Path.basename(final),
              "source" => info.source, "url" => info.url, "bytes" => File.stat!(final).size,
              "fetchedAt" => DateTime.utc_now() |> DateTime.to_iso8601()}

    index = read_index()
    images = Map.put(index["images"] || %{}, info.build, entry)
    :ok = AtomicFile.write(index_path(), Jason.encode!(Map.put(index, "images", images), pretty: true))
    entry
  end

  defp size_sane(path) do
    case File.stat(path) do
      {:ok, %{size: s}} when s > 0 -> :ok
      _ -> {:error, :empty_image}
    end
  end

  defp validate_build(b) when is_binary(b) do
    if b != "" and b not in [".", ".."] and not String.contains?(b, ["/", "\\"]),
      do: :ok, else: {:error, :bad_build_token}
  end

  defp validate_build(_), do: {:error, :bad_build_token}

  defp default_deps do
    %{image_info: &VzBeam.Sidecar.image_info/1, download: &download/2, copy: &cp_clone/2}
  end

  defp cp_clone(src, dst) do
    case System.cmd("cp", ["-c", src, dst], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, {:copy_failed, String.trim(out)}}
    end
  end

  defp download(url, dst) do
    case System.cmd("curl", ["-fL", "-o", dst, url], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, {:download_failed, String.trim(out)}}
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/cache_test.exs`
Expected: PASS (fetch/idempotent/list, reconcile, build-token rejection).

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/cache.ex test/cache_test.exs
git commit -m "feat: VzBeam.Cache IPSW store + index with ensure/2"
```

---

## Task 8: `fetch` verb

**Files:**
- Create: `lib/vzbeam/commands/fetch.ex`, `test/commands/fetch_test.exs`
- Modify: `lib/vzbeam/cli.ex` (dispatch + `@usage`)

**Interfaces:**
- Consumes: `Cache.ensure/2` (Task 7).
- Produces: `Fetch.run(args, deps \\ %{ensure: &Cache.ensure/1}) :: {:ok, iodata} | {:error, code, iodata}`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/commands/fetch_test.exs
defmodule VzBeam.Commands.FetchTest do
  use ExUnit.Case, async: false

  test "prints version+build on a successful fetch" do
    deps = %{ensure: fn "/img.ipsw" -> {:ok, :fetched, %{"version" => "26.5.1", "build" => "25F80"}} end}
    assert {:ok, out} = VzBeam.Commands.Fetch.run(["/img.ipsw"], deps)
    assert IO.iodata_to_binary(out) =~ "26.5.1 (25F80)"
  end

  test "surfaces an error" do
    deps = %{ensure: fn _ -> {:error, :bad_build_token} end}
    assert {:error, 1, msg} = VzBeam.Commands.Fetch.run(["x"], deps)
    assert IO.iodata_to_binary(msg) =~ "bad_build_token"
  end

  test "usage error with no spec" do
    assert {:error, 2, _} = VzBeam.Commands.Fetch.run([], %{ensure: fn _ -> :unused end})
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/commands/fetch_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Write the verb + wire the CLI**

```elixir
# lib/vzbeam/commands/fetch.ex
defmodule VzBeam.Commands.Fetch do
  @moduledoc "fetch <latest|PATH> — download/cache a restore image."

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run(args), do: run(args, %{ensure: &VzBeam.Cache.ensure/1})

  def run([spec], %{ensure: ensure}) do
    case ensure.(spec) do
      {:ok, status, e} -> {:ok, [verb(status), " ", e["version"], " (", e["build"], ")\n"]}
      {:error, reason} -> {:error, 1, ["fetch failed: ", inspect(reason), "\n"]}
    end
  end

  def run(_, _), do: {:error, 2, "usage: vzbeam fetch <latest|PATH>\n"}

  defp verb(:cached), do: "already cached"
  defp verb(_), do: "fetched"
end
```

```elixir
# lib/vzbeam/cli.ex — add a clause (keep existing ip/ls clauses) before the catch-all
  def run(["fetch" | rest]), do: VzBeam.Commands.Fetch.run(rest)
```

```elixir
# lib/vzbeam/cli.ex — extend @usage Commands block
    fetch <latest|PATH> download/cache a restore image
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/commands/fetch_test.exs test/cli_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/commands/fetch.ex test/commands/fetch_test.exs lib/vzbeam/cli.ex
git commit -m "feat: fetch verb"
```

---

## Task 9: `images` verb (+ shared `VzBeam.Table`)

**Files:**
- Create: `lib/vzbeam/table.ex`, `lib/vzbeam/commands/images.ex`, `test/table_test.exs`, `test/commands/images_test.exs`
- Modify: `lib/vzbeam/commands/ls.ex` (reuse the shared renderer), `lib/vzbeam/cli.ex`

**Interfaces:**
- Consumes: `Cache.list/0` (Task 7).
- Produces: `VzBeam.Table.render(rows :: [[String.t()]]) :: iodata` (pads each column to its widest cell + 2 spaces, newline-terminates each row — extracted verbatim from `Ls`'s private renderer); `Images.run(args, list_fn \\ &Cache.list/0) :: {:ok, iodata}`.
- Refactor: `Ls` drops its private `render/1` and calls `VzBeam.Table.render/1` (DRY — pre-flight finding; output identical, so `ls_test` stays green).

- [ ] **Step 1: Write the failing tests**

```elixir
# test/table_test.exs
defmodule VzBeam.TableTest do
  use ExUnit.Case, async: true

  test "pads each column to its widest cell + 2 and newline-terminates rows" do
    out = VzBeam.Table.render([["NAME", "OS"], ["base", "26.5.1"]]) |> IO.iodata_to_binary()
    assert out == "NAME  OS      \nbase  26.5.1  \n"
  end
end
```

```elixir
# test/commands/images_test.exs
defmodule VzBeam.Commands.ImagesTest do
  use ExUnit.Case, async: true

  test "renders a table with header and rows" do
    list = fn -> [%{"version" => "26.5.1", "build" => "25F80", "bytes" => 16_000_000_000, "source" => "latest"}] end
    assert {:ok, out} = VzBeam.Commands.Images.run([], list)
    text = IO.iodata_to_binary(out)
    assert text =~ ~r/VERSION\s+BUILD\s+SIZE\s+SOURCE/
    assert text =~ "25F80"
  end

  test "empty cache prints just the header" do
    assert {:ok, out} = VzBeam.Commands.Images.run([], fn -> [] end)
    assert IO.iodata_to_binary(out) =~ "VERSION"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/table_test.exs test/commands/images_test.exs`
Expected: FAIL — modules undefined.

- [ ] **Step 3: Extract `Table`, refactor `Ls`, write `Images`, wire the CLI**

```elixir
# lib/vzbeam/table.ex  (NEW — shared renderer, extracted verbatim from Ls)
defmodule VzBeam.Table do
  @moduledoc "Render equal-length string rows as a padded text table (iodata)."

  @spec render([[String.t()]]) :: iodata
  def render(rows) do
    widths =
      rows
      |> Enum.zip()
      |> Enum.map(fn col -> col |> Tuple.to_list() |> Enum.map(&String.length/1) |> Enum.max() end)

    Enum.map(rows, fn cols ->
      cols
      |> Enum.zip(widths)
      |> Enum.map(fn {c, w} -> String.pad_trailing(c, w + 2) end)
      |> then(&[&1, "\n"])
    end)
  end
end
```

```elixir
# lib/vzbeam/commands/ls.ex — DELETE the private `render/1`; call the shared renderer.
# Change the run/2 body's final line to:
    {:ok, VzBeam.Table.render([@header | rows])}
# ...and remove the whole `defp render(rows) do ... end` function. No other change; output is identical.
```

```elixir
# lib/vzbeam/commands/images.ex
defmodule VzBeam.Commands.Images do
  @moduledoc "images — list cached restore images."

  @header ["VERSION", "BUILD", "SIZE", "SOURCE"]

  @spec run([String.t()]) :: {:ok, iodata}
  def run(args), do: run(args, &VzBeam.Cache.list/0)

  def run(_args, list_fn) do
    rows =
      Enum.map(list_fn.(), fn e ->
        [e["version"] || "-", e["build"] || "-", size(e["bytes"]), e["source"] || "-"]
      end)

    {:ok, VzBeam.Table.render([@header | rows])}
  end

  defp size(b) when is_number(b), do: "#{trunc(b / (1024 * 1024 * 1024))}G"
  defp size(_), do: "-"
end
```

```elixir
# lib/vzbeam/cli.ex — add clause + @usage line
  def run(["images" | rest]), do: VzBeam.Commands.Images.run(rest)
```
```
    images             list cached restore images
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/table_test.exs test/commands/images_test.exs test/commands/ls_test.exs`
Expected: PASS (Ls output unchanged).

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/table.ex lib/vzbeam/commands/images.ex lib/vzbeam/commands/ls.ex test/table_test.exs test/commands/images_test.exs lib/vzbeam/cli.ex
git commit -m "feat: images verb; extract shared VzBeam.Table renderer (Ls reuses it)"
```

---

## Task 10: `new` verb (clone + restore)

**Files:**
- Create: `lib/vzbeam/commands/new.ex`, `test/commands/new_test.exs`
- Modify: `lib/vzbeam/cli.ex`

**Interfaces:**
- Consumes: `Manifest.read/1`, `Pidfile.running?/1`, `Home.bundle_dir/1`, `AtomicFile.write/2`, `Cache.ensure/1`+`Cache.dir/0`, `Sidecar.reid/0`, `Sidecar.restore/1`, `Defaults.resolve/2`.
- Produces: `New.run(args, deps \\ default_deps()) :: {:ok, iodata} | {:error, code, iodata}` where `deps = %{reid, ensure, restore}`.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/commands/new_test.exs
defmodule VzBeam.Commands.NewTest do
  use ExUnit.Case, async: false
  alias VzBeam.Commands.New

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    File.mkdir_p!(Path.join(home, "base"))
    File.write!(Path.join([home, "base", "config.json"]),
      Jason.encode!(%{"name" => "base", "base" => nil, "macAddress" => "5e:00",
                      "machineIdentifier" => "OLD", "hardwareModel" => "HW",
                      "cpuCount" => 4, "memoryBytes" => 8_589_934_592,
                      "image" => %{"version" => "26.5.1", "build" => "25F80"}}))
    File.write!(Path.join([home, "base", "disk.img"]), "DISK")
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    {:ok, home: home}
  end

  defp deps do
    %{
      reid: fn -> {:ok, %{machine_identifier: "NEW", mac_address: "5e:ff"}} end,
      ensure: fn _ -> {:ok, :fetched, %{"version" => "26.5.1", "build" => "25F80", "file" => "25F80.ipsw"}} end,
      restore: fn opts -> File.touch!(opts.aux);
        {:ok, %{machine_identifier: "RID", hardware_model: "HW2", mac_address: "5e:ab",
                version: "26.5.1", build: "25F80"}} end
    }
  end

  test "clone copies the bundle and re-identifies it", %{home: home} do
    assert {:ok, _} = New.run(["dev", "base"], deps())
    m = Jason.decode!(File.read!(Path.join([home, "dev", "config.json"])))
    assert m["base"] == "base" and m["machineIdentifier"] == "NEW" and m["macAddress"] == "5e:ff"
    assert m["cpuCount"] == 4                      # inherited
    assert File.read!(Path.join([home, "dev", "disk.img"])) == "DISK"  # cloned
    refute File.exists?(Path.join(home, "dev.pending"))
  end

  test "clone refuses a running base", %{home: home} do
    :ok = VzBeam.Pidfile.write("base", System.pid())
    assert {:error, 1, msg} = New.run(["dev", "base"], deps())
    assert IO.iodata_to_binary(msg) =~ "running"
  end

  test "clone refuses a reserved name" do
    assert {:error, 1, msg} = New.run(["cache", "base"], deps())
    assert IO.iodata_to_binary(msg) =~ "reserved"
  end

  test "restore creates a fresh base with disk.img + aux.img", %{home: home} do
    assert {:ok, _} = New.run(["fresh", "--image", "latest"], deps())
    assert File.regular?(Path.join([home, "fresh", "disk.img"]))
    assert File.regular?(Path.join([home, "fresh", "aux.img"]))
    m = Jason.decode!(File.read!(Path.join([home, "fresh", "config.json"])))
    assert m["base"] == nil and m["machineIdentifier"] == "RID"
  end

  test "--image is mutually exclusive with a base" do
    assert {:error, 2, _} = New.run(["dev", "base", "--image", "latest"], deps())
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/commands/new_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Write the verb + wire the CLI**

```elixir
# lib/vzbeam/commands/new.ex
defmodule VzBeam.Commands.New do
  @moduledoc "new <name> <base> | new <name> --image <latest|PATH>"
  alias VzBeam.{Home, Manifest, Pidfile, AtomicFile, Cache, Defaults}

  @reserved ~w(cache keys bin run.lock)
  @gb 1024 * 1024 * 1024

  def run(args), do: run(args, default_deps())

  def run(args, deps) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: [image: :string, cpu: :integer, mem_gb: :integer, disk_gb: :integer])

    case {positional, opts[:image]} do
      {[name, base], nil} -> clone(name, base, deps)
      {[name], img} when is_binary(img) -> restore(name, img, opts, deps)
      {[_, _], img} when is_binary(img) -> {:error, 2, "new: --image is mutually exclusive with a base\n"}
      _ -> {:error, 2, "usage: vzbeam new <name> <base> | new <name> --image <latest|PATH>\n"}
    end
  end

  # --- clone ---------------------------------------------------------------
  defp clone(name, base, deps) do
    pending = Home.bundle_dir(name) <> ".pending"

    with :ok <- validate_name(name),
         {:ok, base_m} <- read_base(base),
         :ok <- refute_running(base),
         :ok <- refute_exists(name),
         _ <- File.rm_rf(pending),
         :ok <- cp_rc(Home.bundle_dir(base), pending),
         {:ok, ids} <- deps.reid.(),
         :ok <- write_manifest(pending, clone_manifest(base_m, name, base, ids)),
         :ok <- File.rename(pending, Home.bundle_dir(name)) do
      {:ok, ["created ", name, " (clone of ", base, ")\n"]}
    else
      err -> File.rm_rf(pending); error(err)
    end
  end

  defp clone_manifest(base_m, name, base, ids) do
    Map.merge(base_m, %{
      "name" => name, "base" => base,
      "machineIdentifier" => ids.machine_identifier, "macAddress" => ids.mac_address,
      "createdAt" => now()
    })
  end

  # --- restore -------------------------------------------------------------
  defp restore(name, spec, opts, deps) do
    pending = Home.bundle_dir(name) <> ".pending"
    disk_bytes = Defaults.resolve(opts[:disk_gb], :disk_gb) * @gb
    cpu = Defaults.resolve(opts[:cpu], :cpu)
    mem_bytes = Defaults.resolve(opts[:mem_gb], :mem_gb) * @gb

    with :ok <- validate_name(name),
         :ok <- refute_exists(name),
         {:ok, _status, entry} <- deps.ensure.(spec),
         _ <- File.rm_rf(pending),
         :ok <- File.mkdir_p(pending),
         :ok <- create_sparse(Path.join(pending, "disk.img"), disk_bytes),
         {:ok, r} <- deps.restore.(%{ipsw: Path.join(Cache.dir(), entry["file"]),
             disk: Path.join(pending, "disk.img"), aux: Path.join(pending, "aux.img"),
             disk_size: disk_bytes, cpu: cpu, mem: mem_bytes}),
         :ok <- write_manifest(pending, restore_manifest(name, entry, r, cpu, mem_bytes)),
         :ok <- File.rename(pending, Home.bundle_dir(name)) do
      {:ok, ["created ", name, " (cpu=#{cpu} mem=#{div(mem_bytes, @gb)}G disk=#{div(disk_bytes, @gb)}G)\n"]}
    else
      err -> File.rm_rf(pending); error(err)
    end
  end

  defp restore_manifest(name, entry, r, cpu, mem_bytes) do
    %{"name" => name, "base" => nil,
      "image" => %{"version" => entry["version"], "build" => entry["build"], "source" => entry["source"]},
      "machineIdentifier" => r.machine_identifier, "hardwareModel" => r.hardware_model,
      "macAddress" => r.mac_address, "cpuCount" => cpu, "memoryBytes" => mem_bytes,
      "createdAt" => now()}
  end

  # --- helpers -------------------------------------------------------------
  defp validate_name(n) do
    cond do
      n in @reserved -> {:error, :reserved_name}
      n == "" or n in [".", ".."] or String.contains?(n, ["/", "\\"]) -> {:error, :bad_name}
      true -> :ok
    end
  end

  defp read_base(base) do
    case Manifest.read(base), do: ({:ok, m} -> {:ok, m}; _ -> {:error, :no_such_base})
  end

  defp refute_running(base), do: if(Pidfile.running?(base), do: {:error, :base_running}, else: :ok)
  defp refute_exists(name), do: if(Home.exists?(name), do: {:error, :exists}, else: :ok)

  defp cp_rc(src, dst) do
    case System.cmd("cp", ["-Rc", src, dst], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, {:clone_failed, String.trim(out)}}
    end
  end

  defp write_manifest(dir, map) do
    AtomicFile.write(Path.join(dir, "config.json"), Jason.encode!(Map.put(map, "schemaVersion", 1), pretty: true))
  end

  defp create_sparse(path, size) do
    File.open(path, [:write, :raw], fn fd -> :file.pwrite(fd, size - 1, <<0>>) end)
    |> case do
      {:ok, :ok} -> :ok
      {:ok, err} -> err
      err -> err
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp error({:error, :reserved_name}), do: {:error, 1, "new: name is reserved\n"}
  defp error({:error, :bad_name}), do: {:error, 1, "new: invalid name\n"}
  defp error({:error, :no_such_base}), do: {:error, 1, "new: no such base\n"}
  defp error({:error, :base_running}), do: {:error, 1, "new: base is running; stop it first\n"}
  defp error({:error, :exists}), do: {:error, 1, "new: bundle already exists\n"}
  defp error({:error, reason}), do: {:error, 1, ["new failed: ", inspect(reason), "\n"]}

  defp default_deps,
    do: %{reid: &VzBeam.Sidecar.reid/0, ensure: &Cache.ensure/1, restore: &VzBeam.Sidecar.restore/1}
end
```

```elixir
# lib/vzbeam/cli.ex — add clause + @usage lines
  def run(["new" | rest]), do: VzBeam.Commands.New.run(rest)
```
```
    new <name> <base>  clone a stopped base (CoW)
    new <name> --image <latest|PATH>  restore a fresh base
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/commands/new_test.exs`
Expected: PASS (clone, running-base refusal, reserved-name refusal, restore, mutual exclusion).

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/commands/new.ex test/commands/new_test.exs lib/vzbeam/cli.ex
git commit -m "feat: new verb (clone + restore)"
```

---

## Task 11: `rm` verb

**Files:**
- Create: `lib/vzbeam/commands/rm.ex`, `test/commands/rm_test.exs`
- Modify: `lib/vzbeam/cli.ex`

**Interfaces:**
- Consumes: `Home.exists?/1`, `Home.bundle_dir/1`, `Pidfile.running?/1`.
- Produces: `Rm.run(args) :: {:ok, iodata} | {:error, code, iodata}`.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/commands/rm_test.exs
defmodule VzBeam.Commands.RmTest do
  use ExUnit.Case, async: false

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    File.mkdir_p!(Path.join(home, "dev"))
    File.write!(Path.join([home, "dev", "config.json"]), "{}")
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    {:ok, home: home}
  end

  test "removes a stopped bundle", %{home: home} do
    assert {:ok, _} = VzBeam.Commands.Rm.run(["dev"])
    refute File.exists?(Path.join(home, "dev"))
  end

  test "refuses a running bundle" do
    :ok = VzBeam.Pidfile.write("dev", System.pid())
    assert {:error, 1, msg} = VzBeam.Commands.Rm.run(["dev"])
    assert IO.iodata_to_binary(msg) =~ "running"
  end

  test "errors on a missing bundle" do
    assert {:error, 1, msg} = VzBeam.Commands.Rm.run(["ghost"])
    assert IO.iodata_to_binary(msg) =~ "no such bundle"
  end

  test "usage error with no name" do
    assert {:error, 2, _} = VzBeam.Commands.Rm.run([])
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/commands/rm_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Write the verb + wire the CLI**

```elixir
# lib/vzbeam/commands/rm.ex
defmodule VzBeam.Commands.Rm do
  @moduledoc "rm <name> — delete a stopped bundle (--force/stop arrive in Plan 3)."
  alias VzBeam.{Home, Pidfile}

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run([name]) do
    cond do
      not Home.exists?(name) -> {:error, 1, ["no such bundle: ", name, "\n"]}
      Pidfile.running?(name) -> {:error, 1, [name, " is running; stop it first\n"]}
      true -> File.rm_rf!(Home.bundle_dir(name)); {:ok, ["removed ", name, "\n"]}
    end
  end

  def run(_), do: {:error, 2, "usage: vzbeam rm <name>\n"}
end
```

```elixir
# lib/vzbeam/cli.ex — add clause + @usage line
  def run(["rm" | rest]), do: VzBeam.Commands.Rm.run(rest)
```
```
    rm <name>          delete a stopped bundle
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/commands/rm_test.exs test/cli_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the full suite + build the escript**

Run: `mix test && mix escript.build`
Expected: all green; `./vzbeam` builds.

- [ ] **Step 6: Commit**

```bash
git add lib/vzbeam/commands/rm.ex test/commands/rm_test.exs lib/vzbeam/cli.ex
git commit -m "feat: rm verb"
```

---

## Self-Review (completed during planning)

- **Spec coverage:** `fetch`/`images`/`new`(clone)/`new`(restore)/`rm` → Tasks 8/9/10/10/11; `Protocol`/`Sidecar`/`Cache`/`AtomicFile` → Tasks 5/6/7/1; cleanups (AtomicFile, Pidfile pid+errors, lease dedup, `Ls` numeric, `Home` `.pending`) → Tasks 1–4. Codex findings #1 (reconcile, Task 7), #3 (`Home` filter, Task 4), #4 (`rm` no `--force`, Task 11), #6 (`:unterminated`, Tasks 5/6), #7 (build-token, Task 7) all have tasks. #2 (cache lock) intentionally deferred (unique pending names are in Task 7). #5/#8 are spec wording (no code).
- **Placeholder scan:** none — every step carries real code/commands.
- **Type consistency:** `ensure/2` → `{:ok, status, entry}` consumed as `{:ok, _status, entry}` in `New` and `{:ok, status, e}` in `Fetch`; `reid`/`restore` return atom-keyed maps consumed via `.machine_identifier`/`.mac_address`/`.aux`; `Home.exists?/1` defined in Task 4, used in Tasks 10/11; `Cache.dir/0` defined Task 7, used Task 10.
- **Note on flags:** `new --image` accepts `--cpu/--mem-gb/--disk-gb` via `OptionParser` (resolved through `Defaults`); clone inherits the base's sizing (per spec §6 / decision in §8).

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-06-23-vzbeam-image-clone.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — fresh subagent per task, two-stage review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session via executing-plans, batch with checkpoints.

**Which approach?**
