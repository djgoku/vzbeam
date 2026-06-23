# vzbeam Engine Foundation (+ `ls`/`ip`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the Elixir CLI engine skeleton and deliver two working read-only verbs — `vzbeam ls` and `vzbeam ip` — fully testable on this (non-booting) dev box.

**Architecture:** A plain `mix` escript project. `VzBeam.CLI.run/1` parses argv and dispatches to per-verb command modules; `main/1` is a thin wrapper that prints and sets the exit code (so tests drive `run/1` and never hit `System.halt`). Pure modules own each concern: `Home` (paths), `Defaults` (constants), `Manifest` (per-bundle `config.json`), `Pidfile` (`vm.pid` + liveness), `Leases` (DHCP parsing). All I/O is in Elixir; no Swift yet.

**Tech Stack:** Elixir (escript), Jason (JSON), ExUnit, `ps` (process liveness). macOS / arm64.

## Global Constraints

- **JSON everywhere**, one parser: **Jason** (`~> 1.4`). Manifest, `vm.pid`, and (later) the wire/image-index are all JSON.
- **`schemaVersion: 1`** on every manifest; unknown JSON keys are preserved on read-modify-write.
- **`$VZBEAM_HOME`** is the single storage switch: env `VZBEAM_HOME` else default `~/.local/share/vzbeam`.
- **No `Mix.*` at runtime** — use `System`/`Application`, never `Mix.env` etc. in `lib/`.
- **Atomic writes**: every state-file write is write-temp-then-`rename`.
- **One clean entrypoint** `VzBeam.CLI.main/1` (escript today, Burrito later). `run/1` holds the logic; `main/1` only prints + exits.
- Platform: macOS, arm64. Target Elixir `~> 1.17`.

---

## File Structure

- `mix.exs` — project + escript config + Jason dep.
- `lib/vzbeam/cli.ex` — `main/1`, `run/1`, verb dispatch, usage text.
- `lib/vzbeam/home.ex` — `$VZBEAM_HOME` resolution + path helpers + bundle enumeration.
- `lib/vzbeam/defaults.ex` — built-in default constants + `resolve/2` + `describe/0`.
- `lib/vzbeam/manifest.ex` — read/write per-bundle `config.json` (atomic, schema-checked).
- `lib/vzbeam/pidfile.ex` — `vm.pid` JSON read/write + PID-reuse-safe liveness.
- `lib/vzbeam/leases.ex` — pure `/var/db/dhcpd_leases` parser + MAC→IP lookup.
- `lib/vzbeam/commands/ip.ex` — `ip <name>` verb.
- `lib/vzbeam/commands/ls.ex` — `ls` verb (table).
- `test/...` — one test file per module above.

Dependency order: `Home`/`Defaults` → `Manifest`/`Pidfile`/`Leases` → `Commands.Ip`/`Commands.Ls` → CLI wiring.

---

## Task 1: Project scaffold + CLI dispatch skeleton

**Files:**
- Create: `mix.exs`, `lib/vzbeam/cli.ex`
- Test: `test/cli_test.exs`, `test/test_helper.exs`

**Interfaces:**
- Produces: `VzBeam.CLI.run(argv :: [String.t()]) :: {:ok, iodata} | {:error, exit_code :: non_neg_integer, iodata}`; `VzBeam.CLI.main(argv) :: no_return` (prints + `System.halt`).

- [ ] **Step 1: Prerequisite — install the Elixir toolchain**

This box has no `mix`. Install Erlang/Elixir (mise is already present):

Run: `mise use -g erlang@latest elixir@latest && mix --version`
Expected: prints `Mix x.y.z` (if `mise` is unavailable, use `brew install elixir`).

- [ ] **Step 2: Create the mix project files**

`mix.exs`:
```elixir
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
```

`test/test_helper.exs`:
```elixir
ExUnit.start()
```

- [ ] **Step 3: Write the failing test**

`test/cli_test.exs`:
```elixir
defmodule VzBeam.CLITest do
  use ExUnit.Case, async: true

  test "no args returns usage as an error" do
    assert {:error, 2, usage} = VzBeam.CLI.run([])
    assert IO.iodata_to_binary(usage) =~ "Usage: vzbeam"
  end

  test "--help returns usage as ok" do
    assert {:ok, usage} = VzBeam.CLI.run(["--help"])
    assert IO.iodata_to_binary(usage) =~ "ls"
  end

  test "unknown verb errors with exit code 2" do
    assert {:error, 2, msg} = VzBeam.CLI.run(["bogus"])
    assert IO.iodata_to_binary(msg) =~ "unknown command: bogus"
  end
end
```

- [ ] **Step 4: Run the test, verify it fails**

Run: `mix deps.get && mix test test/cli_test.exs`
Expected: FAIL — `VzBeam.CLI.run/1` undefined.

- [ ] **Step 5: Implement `VzBeam.CLI`**

`lib/vzbeam/cli.ex`:
```elixir
defmodule VzBeam.CLI do
  @moduledoc "Entry point: parse argv, dispatch to a verb, return {:ok|:error}."

  @usage """
  Usage: vzbeam <command> [args]

  Commands:
    ls                 list VM bundles
    ip <name>          print a VM's IP (from DHCP leases)
  """

  @spec main([String.t()]) :: no_return
  def main(argv) do
    case run(argv) do
      {:ok, out} -> IO.write(out)
      {:error, code, out} -> IO.write(:stderr, out); System.halt(code)
    end
  end

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run([]), do: {:error, 2, @usage}
  def run(["--help"]), do: {:ok, @usage}
  def run(["help"]), do: {:ok, @usage}
  def run(["ip" | rest]), do: VzBeam.Commands.Ip.run(rest)
  def run(["ls" | rest]), do: VzBeam.Commands.Ls.run(rest)
  def run([verb | _]), do: {:error, 2, ["unknown command: ", verb, "\n", @usage]}
end
```

For Task 1 only, stub the two command modules so the module compiles. Create `lib/vzbeam/commands/ip.ex` and `lib/vzbeam/commands/ls.ex` each with `def run(_), do: {:ok, ""}` — they are fully implemented in Tasks 7–8.

- [ ] **Step 6: Run the test, verify it passes**

Run: `mix test test/cli_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 7: Commit**

```bash
git add mix.exs lib/vzbeam/cli.ex lib/vzbeam/commands/ip.ex lib/vzbeam/commands/ls.ex test/
git commit -m "feat: mix escript scaffold + CLI dispatch skeleton"
```

---

## Task 2: `VzBeam.Home` — storage root + paths

**Files:**
- Create: `lib/vzbeam/home.ex`
- Test: `test/home_test.exs`

**Interfaces:**
- Produces: `Home.root() :: Path.t()`; `Home.bundle_dir(name :: String.t()) :: Path.t()`; `Home.bundles() :: [String.t()]` (names of subdirs containing a `config.json`).

- [ ] **Step 1: Write the failing test**

`test/home_test.exs`:
```elixir
defmodule VzBeam.HomeTest do
  use ExUnit.Case, async: false

  test "root honors VZBEAM_HOME env" do
    System.put_env("VZBEAM_HOME", "/tmp/vzbeam-test-home")
    assert VzBeam.Home.root() == "/tmp/vzbeam-test-home"
  after
    System.delete_env("VZBEAM_HOME")
  end

  test "root defaults under ~/.local/share/vzbeam" do
    System.delete_env("VZBEAM_HOME")
    assert VzBeam.Home.root() == Path.expand("~/.local/share/vzbeam")
  end

  test "bundles lists only dirs containing config.json" do
    home = Path.join(System.tmp_dir!(), "vzbeam-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "base"))
    File.write!(Path.join([home, "base", "config.json"]), "{}")
    File.mkdir_p!(Path.join(home, "notabundle"))
    System.put_env("VZBEAM_HOME", home)
    assert VzBeam.Home.bundles() == ["base"]
  after
    System.delete_env("VZBEAM_HOME")
  end
end
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `mix test test/home_test.exs`
Expected: FAIL — `VzBeam.Home` undefined.

- [ ] **Step 3: Implement `VzBeam.Home`**

`lib/vzbeam/home.ex`:
```elixir
defmodule VzBeam.Home do
  @moduledoc "Resolves $VZBEAM_HOME and bundle paths."

  @spec root() :: Path.t()
  def root do
    case System.get_env("VZBEAM_HOME") do
      nil -> Path.expand("~/.local/share/vzbeam")
      "" -> Path.expand("~/.local/share/vzbeam")
      dir -> dir
    end
  end

  @spec bundle_dir(String.t()) :: Path.t()
  def bundle_dir(name), do: Path.join(root(), name)

  @spec bundles() :: [String.t()]
  def bundles do
    case File.ls(root()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&File.regular?(Path.join([root(), &1, "config.json"])))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end
end
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `mix test test/home_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/home.ex test/home_test.exs
git commit -m "feat: VzBeam.Home storage root + bundle enumeration"
```

---

## Task 3: `VzBeam.Defaults` — built-in defaults

**Files:**
- Create: `lib/vzbeam/defaults.ex`
- Test: `test/defaults_test.exs`

**Interfaces:**
- Produces: `Defaults.values() :: %{cpu: 4, mem_gb: 8, disk_gb: 64, resolution: "1920x1200", ssh_user: "admin"}`; `Defaults.resolve(flag_value :: any | nil, key :: atom) :: any` (flag wins over default); `Defaults.describe() :: String.t()`.

- [ ] **Step 1: Write the failing test**

`test/defaults_test.exs`:
```elixir
defmodule VzBeam.DefaultsTest do
  use ExUnit.Case, async: true

  test "values has the five defaults" do
    v = VzBeam.Defaults.values()
    assert v.cpu == 4 and v.mem_gb == 8 and v.disk_gb == 64
    assert v.resolution == "1920x1200" and v.ssh_user == "admin"
  end

  test "resolve prefers a non-nil flag over the default" do
    assert VzBeam.Defaults.resolve(8, :cpu) == 8
    assert VzBeam.Defaults.resolve(nil, :cpu) == 4
  end

  test "describe mentions override flags" do
    assert VzBeam.Defaults.describe() =~ "--cpu"
  end
end
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `mix test test/defaults_test.exs`
Expected: FAIL — `VzBeam.Defaults` undefined.

- [ ] **Step 3: Implement `VzBeam.Defaults`**

`lib/vzbeam/defaults.ex`:
```elixir
defmodule VzBeam.Defaults do
  @moduledoc "Built-in default sizing — no config file in the MVP."

  @values %{cpu: 4, mem_gb: 8, disk_gb: 64, resolution: "1920x1200", ssh_user: "admin"}

  @spec values() :: map
  def values, do: @values

  @spec resolve(any | nil, atom) :: any
  def resolve(nil, key), do: Map.fetch!(@values, key)
  def resolve(flag_value, _key), do: flag_value

  @spec describe() :: String.t()
  def describe do
    "defaults: cpu=#{@values.cpu} mem=#{@values.mem_gb}G disk=#{@values.disk_gb}G " <>
      "(override with --cpu/--mem-gb/--disk-gb)"
  end
end
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `mix test test/defaults_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/defaults.ex test/defaults_test.exs
git commit -m "feat: VzBeam.Defaults built-in sizing"
```

---

## Task 4: `VzBeam.Manifest` — per-bundle config.json

**Files:**
- Create: `lib/vzbeam/manifest.ex`
- Test: `test/manifest_test.exs`

**Interfaces:**
- Consumes: `Home.bundle_dir/1`.
- Produces: `Manifest.path(name) :: Path.t()`; `Manifest.read(name) :: {:ok, map} | {:error, term}` (string-keyed map, schema-checked); `Manifest.write(name, map :: map) :: :ok | {:error, term}` (atomic, injects `schemaVersion: 1`, preserves unknown keys).

- [ ] **Step 1: Write the failing test**

`test/manifest_test.exs`:
```elixir
defmodule VzBeam.ManifestTest do
  use ExUnit.Case, async: false

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "base"))
    System.put_env("VZBEAM_HOME", home)
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    {:ok, home: home}
  end

  test "write then read round-trips and adds schemaVersion" do
    :ok = VzBeam.Manifest.write("base", %{"name" => "base", "macAddress" => "5e:aa"})
    assert {:ok, m} = VzBeam.Manifest.read("base")
    assert m["name"] == "base"
    assert m["schemaVersion"] == 1
  end

  test "read of a missing manifest errors" do
    assert {:error, _} = VzBeam.Manifest.read("ghost")
  end

  test "unknown keys survive a read-modify-write" do
    :ok = VzBeam.Manifest.write("base", %{"name" => "base", "future" => "keepme"})
    {:ok, m} = VzBeam.Manifest.read("base")
    :ok = VzBeam.Manifest.write("base", Map.put(m, "cpuCount", 4))
    {:ok, m2} = VzBeam.Manifest.read("base")
    assert m2["future"] == "keepme" and m2["cpuCount"] == 4
  end
end
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `mix test test/manifest_test.exs`
Expected: FAIL — `VzBeam.Manifest` undefined.

- [ ] **Step 3: Implement `VzBeam.Manifest`**

`lib/vzbeam/manifest.ex`:
```elixir
defmodule VzBeam.Manifest do
  @moduledoc "Read/write a bundle's config.json (atomic, schema-stamped)."
  alias VzBeam.Home

  @schema_version 1

  @spec path(String.t()) :: Path.t()
  def path(name), do: Path.join(Home.bundle_dir(name), "config.json")

  @spec read(String.t()) :: {:ok, map} | {:error, term}
  def read(name) do
    with {:ok, body} <- File.read(path(name)),
         {:ok, map} <- Jason.decode(body) do
      {:ok, map}
    end
  end

  @spec write(String.t(), map) :: :ok | {:error, term}
  def write(name, map) when is_map(map) do
    stamped = Map.put(map, "schemaVersion", @schema_version)
    body = Jason.encode!(stamped, pretty: true)
    target = path(name)
    tmp = target <> ".tmp.#{System.unique_integer([:positive])}"

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

- [ ] **Step 4: Run the test, verify it passes**

Run: `mix test test/manifest_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/manifest.ex test/manifest_test.exs
git commit -m "feat: VzBeam.Manifest atomic JSON read/write"
```

---

## Task 5: `VzBeam.Pidfile` — vm.pid + PID-reuse-safe liveness

**Files:**
- Create: `lib/vzbeam/pidfile.ex`
- Test: `test/pidfile_test.exs`

**Interfaces:**
- Consumes: `Home.bundle_dir/1`.
- Produces: `Pidfile.path(name) :: Path.t()`; `Pidfile.process_start(os_pid :: String.t() | integer) :: {:ok, String.t()} | :error` (kernel start time via `ps`); `Pidfile.write(name, os_pid) :: :ok | {:error, term}` (writes `%{"pid","startedAt","bundle"}`, capturing start time now); `Pidfile.read(name) :: {:ok, map} | {:error, term}`; `Pidfile.running?(name) :: boolean` (pid alive AND start time matches recorded `startedAt`).

- [ ] **Step 1: Write the failing test**

`test/pidfile_test.exs`:
```elixir
defmodule VzBeam.PidfileTest do
  use ExUnit.Case, async: false

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "vm"))
    System.put_env("VZBEAM_HOME", home)
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    :ok
  end

  test "process_start succeeds for self, errors for an impossible pid" do
    assert {:ok, _} = VzBeam.Pidfile.process_start(System.pid())
    assert :error = VzBeam.Pidfile.process_start(2_147_483_000)
  end

  test "running? is true right after writing our own pid" do
    :ok = VzBeam.Pidfile.write("vm", System.pid())
    assert VzBeam.Pidfile.running?("vm")
  end

  test "running? is false when startedAt was tampered (PID reuse guard)" do
    :ok = VzBeam.Pidfile.write("vm", System.pid())
    {:ok, m} = VzBeam.Pidfile.read("vm")
    File.write!(VzBeam.Pidfile.path("vm"), Jason.encode!(%{m | "startedAt" => "Bogus Time"}))
    refute VzBeam.Pidfile.running?("vm")
  end

  test "running? is false when there is no pidfile" do
    refute VzBeam.Pidfile.running?("vm")
  end
end
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `mix test test/pidfile_test.exs`
Expected: FAIL — `VzBeam.Pidfile` undefined.

- [ ] **Step 3: Implement `VzBeam.Pidfile`**

`lib/vzbeam/pidfile.ex`:
```elixir
defmodule VzBeam.Pidfile do
  @moduledoc "vm.pid runtime state with PID-reuse-safe liveness."
  alias VzBeam.Home

  @spec path(String.t()) :: Path.t()
  def path(name), do: Path.join(Home.bundle_dir(name), "vm.pid")

  @spec process_start(String.t() | integer) :: {:ok, String.t()} | :error
  def process_start(os_pid) do
    case System.cmd("ps", ["-o", "lstart=", "-p", to_string(os_pid)], stderr_to_stdout: true) do
      {out, 0} ->
        case String.trim(out) do
          "" -> :error
          start -> {:ok, start}
        end

      {_, _} ->
        :error
    end
  end

  @spec write(String.t(), String.t() | integer) :: :ok | {:error, term}
  def write(name, os_pid) do
    with {:ok, started} <- process_start(os_pid) do
      atomic_write(path(name), Jason.encode!(%{
        "pid" => to_string(os_pid),
        "startedAt" => started,
        "bundle" => name
      }))
    else
      :error -> {:error, :process_not_found}
    end
  end

  @spec read(String.t()) :: {:ok, map} | {:error, term}
  def read(name) do
    with {:ok, body} <- File.read(path(name)), do: Jason.decode(body)
  end

  @spec running?(String.t()) :: boolean
  def running?(name) do
    with {:ok, %{"pid" => pid, "startedAt" => started}} <- read(name),
         {:ok, ^started} <- process_start(pid) do
      true
    else
      _ -> false
    end
  end

  defp atomic_write(target, body) do
    tmp = target <> ".tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp, body), :ok <- File.rename(tmp, target) do
      :ok
    else
      err -> File.rm(tmp); err
    end
  end
end
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `mix test test/pidfile_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/pidfile.ex test/pidfile_test.exs
git commit -m "feat: VzBeam.Pidfile with PID-reuse-safe liveness"
```

---

## Task 6: `VzBeam.Leases` — DHCP lease parsing

**Files:**
- Create: `lib/vzbeam/leases.ex`
- Test: `test/leases_test.exs`

**Interfaces:**
- Produces: `Leases.parse(content :: String.t()) :: [%{mac: String.t(), ip: String.t(), name: String.t() | nil}]`; `Leases.lookup_ip(content :: String.t(), mac :: String.t()) :: String.t() | nil` (MAC match is case-insensitive); `Leases.path() :: Path.t()` (`/var/db/dhcpd_leases`).

- [ ] **Step 1: Write the failing test**

`test/leases_test.exs`:
```elixir
defmodule VzBeam.LeasesTest do
  use ExUnit.Case, async: true

  @sample """
  {
  \tname=base
  \tip_address=192.168.64.7
  \thw_address=1,5e:aa:bb:cc:dd:ee
  \tlease=0x600
  }
  {
  \tip_address=192.168.64.9
  \thw_address=1,aa:bb:cc:dd:ee:ff
  }
  """

  test "parse extracts mac/ip/name entries" do
    entries = VzBeam.Leases.parse(@sample)
    assert %{mac: "5e:aa:bb:cc:dd:ee", ip: "192.168.64.7", name: "base"} in entries
    assert length(entries) == 2
  end

  test "lookup_ip matches case-insensitively" do
    assert VzBeam.Leases.lookup_ip(@sample, "5E:AA:BB:CC:DD:EE") == "192.168.64.7"
    assert VzBeam.Leases.lookup_ip(@sample, "00:00:00:00:00:00") == nil
  end
end
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `mix test test/leases_test.exs`
Expected: FAIL — `VzBeam.Leases` undefined.

- [ ] **Step 3: Implement `VzBeam.Leases`**

`lib/vzbeam/leases.ex`:
```elixir
defmodule VzBeam.Leases do
  @moduledoc "Pure parser for /var/db/dhcpd_leases."

  @spec path() :: Path.t()
  def path, do: "/var/db/dhcpd_leases"

  @spec parse(String.t()) :: [%{mac: String.t(), ip: String.t() | nil, name: String.t() | nil}]
  def parse(content) do
    content
    |> String.split("}")
    |> Enum.map(&parse_block/1)
    |> Enum.reject(&is_nil(&1.mac))
  end

  @spec lookup_ip(String.t(), String.t()) :: String.t() | nil
  def lookup_ip(content, mac) do
    want = String.downcase(mac)

    content
    |> parse()
    |> Enum.find_value(fn e -> if e.mac == want, do: e.ip end)
  end

  defp parse_block(block) do
    %{
      mac: extract(block, ~r/hw_address=\d+,([0-9a-fA-F:]+)/) |> downcase(),
      ip: extract(block, ~r/ip_address=([0-9.]+)/),
      name: extract(block, ~r/name=([^\s]+)/)
    }
  end

  defp extract(block, regex) do
    case Regex.run(regex, block) do
      [_, captured] -> captured
      _ -> nil
    end
  end

  defp downcase(nil), do: nil
  defp downcase(s), do: String.downcase(s)
end
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `mix test test/leases_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/leases.ex test/leases_test.exs
git commit -m "feat: VzBeam.Leases dhcpd_leases parser"
```

---

## Task 7: `ip <name>` verb

**Files:**
- Modify: `lib/vzbeam/commands/ip.ex` (replace the Task 1 stub)
- Test: `test/commands/ip_test.exs`

**Interfaces:**
- Consumes: `Manifest.read/1`, `Leases.lookup_ip/2`.
- Produces: `VzBeam.Commands.Ip.run(args :: [String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}`. Reads lease content via an injectable function so it is testable without `/var/db`.

- [ ] **Step 1: Write the failing test**

`test/commands/ip_test.exs`:
```elixir
defmodule VzBeam.Commands.IpTest do
  use ExUnit.Case, async: false

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "base"))
    System.put_env("VZBEAM_HOME", home)
    File.write!(Path.join([home, "base", "config.json"]),
      Jason.encode!(%{"name" => "base", "macAddress" => "5e:aa:bb:cc:dd:ee"}))
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    :ok
  end

  @leases "{\n\tip_address=192.168.64.7\n\thw_address=1,5e:aa:bb:cc:dd:ee\n}\n"

  test "prints the IP for a known bundle" do
    assert {:ok, out} = VzBeam.Commands.Ip.run(["base"], fn -> @leases end)
    assert IO.iodata_to_binary(out) =~ "192.168.64.7"
  end

  test "errors when no lease is found" do
    assert {:error, 1, msg} = VzBeam.Commands.Ip.run(["base"], fn -> "" end)
    assert IO.iodata_to_binary(msg) =~ "no lease"
  end

  test "errors when the bundle is missing" do
    assert {:error, 1, _} = VzBeam.Commands.Ip.run(["ghost"], fn -> @leases end)
  end

  test "errors on missing argument" do
    assert {:error, 2, _} = VzBeam.Commands.Ip.run([])
  end
end
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `mix test test/commands/ip_test.exs`
Expected: FAIL — `run/2` undefined (stub only has `run/1`).

- [ ] **Step 3: Implement `VzBeam.Commands.Ip`**

`lib/vzbeam/commands/ip.ex`:
```elixir
defmodule VzBeam.Commands.Ip do
  @moduledoc "ip <name> — resolve a bundle's IP from DHCP leases."
  alias VzBeam.{Manifest, Leases}

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run(args), do: run(args, &read_leases/0)

  @spec run([String.t()], (-> String.t())) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run([name], read_leases) do
    with {:ok, %{"macAddress" => mac}} <- Manifest.read(name),
         ip when is_binary(ip) <- Leases.lookup_ip(read_leases.(), mac) do
      {:ok, [ip, "\n"]}
    else
      nil -> {:error, 1, ["no lease for ", name, "\n"]}
      {:error, _} -> {:error, 1, ["no such bundle: ", name, "\n"]}
      _ -> {:error, 1, ["bundle ", name, " has no macAddress\n"]}
    end
  end

  def run(_, _), do: {:error, 2, "usage: vzbeam ip <name>\n"}

  defp read_leases do
    case File.read(Leases.path()), do: ({:ok, c} -> c; _ -> "")
  end
end
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `mix test test/commands/ip_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/commands/ip.ex test/commands/ip_test.exs
git commit -m "feat: ip verb"
```

---

## Task 8: `ls` verb (table)

**Files:**
- Modify: `lib/vzbeam/commands/ls.ex` (replace the Task 1 stub)
- Test: `test/commands/ls_test.exs`

**Interfaces:**
- Consumes: `Home.bundles/0`, `Manifest.read/1`, `Pidfile.running?/1`, `Leases.lookup_ip/2`.
- Produces: `VzBeam.Commands.Ls.run(args, read_leases \\ &default/0) :: {:ok, iodata}`. Columns: `NAME STATUS BASE OS IP CPU MEM DISK`.

- [ ] **Step 1: Write the failing test**

`test/commands/ls_test.exs`:
```elixir
defmodule VzBeam.Commands.LsTest do
  use ExUnit.Case, async: false

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    base = %{"name" => "base", "base" => nil, "macAddress" => "5e:00",
             "cpuCount" => 4, "memoryBytes" => 8_589_934_592,
             "image" => %{"version" => "26.5.1", "build" => "25F80"}}
    write_bundle(home, "base", base)
    write_bundle(home, "dev", %{base | "name" => "dev", "base" => "base", "macAddress" => "5e:07"})
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    :ok
  end

  defp write_bundle(home, name, map) do
    File.mkdir_p!(Path.join(home, name))
    File.write!(Path.join([home, name, "config.json"]), Jason.encode!(map))
  end

  test "lists bundles with header and rows" do
    {:ok, out} = VzBeam.Commands.Ls.run([], fn -> "" end)
    text = IO.iodata_to_binary(out)
    assert text =~ ~r/NAME\s+STATUS\s+BASE\s+OS/
    assert text =~ "base"
    assert text =~ "dev"
    assert text =~ "26.5.1 (25F80)"
    assert text =~ "stopped"
  end

  test "empty home prints just the header" do
    System.put_env("VZBEAM_HOME", Path.join(System.tmp_dir!(), "empty-#{System.unique_integer([:positive])}"))
    {:ok, out} = VzBeam.Commands.Ls.run([], fn -> "" end)
    assert IO.iodata_to_binary(out) =~ "NAME"
  end
end
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `mix test test/commands/ls_test.exs`
Expected: FAIL — `run/2` undefined / wrong output.

- [ ] **Step 3: Implement `VzBeam.Commands.Ls`**

`lib/vzbeam/commands/ls.ex`:
```elixir
defmodule VzBeam.Commands.Ls do
  @moduledoc "ls — table of bundles."
  alias VzBeam.{Home, Manifest, Pidfile, Leases}

  @header ["NAME", "STATUS", "BASE", "OS", "IP", "CPU", "MEM", "DISK"]

  @spec run([String.t()]) :: {:ok, iodata}
  def run(args), do: run(args, &read_leases/0)

  @spec run([String.t()], (-> String.t())) :: {:ok, iodata}
  def run(_args, read_leases) do
    leases = read_leases.()
    rows = Enum.map(Home.bundles(), &row(&1, leases))
    {:ok, render([@header | rows])}
  end

  defp row(name, leases) do
    m = case Manifest.read(name), do: ({:ok, map} -> map; _ -> %{})
    img = Map.get(m, "image") || %{}
    [
      name,
      if(Pidfile.running?(name), do: "running", else: "stopped"),
      m["base"] || "-",
      os(img),
      ip(m, leases),
      to_string(m["cpuCount"] || "-"),
      mem(m["memoryBytes"]),
      "-"
    ]
  end

  defp os(%{"version" => v, "build" => b}), do: "#{v} (#{b})"
  defp os(_), do: "-"

  defp ip(%{"macAddress" => mac}, leases) when is_binary(mac),
    do: Leases.lookup_ip(leases, mac) || "-"

  defp ip(_, _), do: "-"

  defp mem(bytes) when is_integer(bytes), do: "#{div(bytes, 1024 * 1024 * 1024)}G"
  defp mem(_), do: "-"

  defp render(rows) do
    widths =
      rows
      |> List.zip()
      |> Enum.map(fn col -> col |> Tuple.to_list() |> Enum.map(&String.length/1) |> Enum.max() end)

    Enum.map(rows, fn cols ->
      cols
      |> Enum.zip(widths)
      |> Enum.map(fn {c, w} -> String.pad_trailing(c, w + 2) end)
      |> then(&[&1, "\n"])
    end)
  end

  defp read_leases do
    case File.read(Leases.path()), do: ({:ok, c} -> c; _ -> "")
  end
end
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `mix test test/commands/ls_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/commands/ls.ex test/commands/ls_test.exs
git commit -m "feat: ls verb table"
```

---

## Task 9: Wire verbs through the CLI + escript smoke test

**Files:**
- Modify: `lib/vzbeam/cli.ex` (already dispatches `ls`/`ip` from Task 1 — verify end-to-end)
- Test: `test/integration_test.exs`

**Interfaces:**
- Consumes: everything above.
- Produces: a built escript at `./vzbeam`.

- [ ] **Step 1: Write the failing test**

`test/integration_test.exs`:
```elixir
defmodule VzBeam.IntegrationTest do
  use ExUnit.Case, async: false

  test "ls runs end-to-end through CLI.run with a populated home" do
    home = Path.join(System.tmp_dir!(), "vzbeam-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "base"))
    File.write!(Path.join([home, "base", "config.json"]), Jason.encode!(%{"name" => "base"}))
    System.put_env("VZBEAM_HOME", home)
    assert {:ok, out} = VzBeam.CLI.run(["ls"])
    assert IO.iodata_to_binary(out) =~ "base"
  after
    System.delete_env("VZBEAM_HOME")
  end
end
```

- [ ] **Step 2: Run the test, verify it fails (or passes if wiring is already correct)**

Run: `mix test test/integration_test.exs`
Expected: PASS once Tasks 7–8 are done (this guards the Task 1 dispatch wiring).

- [ ] **Step 3: Build the escript and smoke-test it**

Run:
```bash
mix escript.build
VZBEAM_HOME=/tmp/vzbeam-smoke ./vzbeam ls
```
Expected: prints a `NAME STATUS …` header (empty body for a fresh home), exit 0.

- [ ] **Step 4: Run the full suite**

Run: `mix test`
Expected: PASS (all tasks' tests green).

- [ ] **Step 5: Commit**

```bash
git add test/integration_test.exs
git commit -m "test: ls/ip end-to-end + escript smoke test"
```

---

## Self-Review

**Spec coverage (Plan 1 slice):** `$VZBEAM_HOME` resolution (T2 ✓), built-in defaults / no config file (T3 ✓), JSON manifest with `schemaVersion` + unknown-key preservation (T4 ✓), `vm.pid` JSON + PID-reuse-safe liveness — Codex #8 (T5 ✓), lease parsing (T6 ✓), `ip` verb (T7 ✓), `ls` with BASE + OS columns (T8 ✓), atomic writes — Codex #12 (T4/T5 ✓), single `CLI.main/1` entrypoint with logic in `run/1` (T1 ✓). Out of this slice by design: `fetch`/`new`/`run`/`rm`/`ssh` (Plans 2–3), the sidecar + protocol decoder (Plans 3–4).

**Placeholder scan:** none — every step has runnable code/commands. The Task 1 command-module stubs are explicitly replaced in Tasks 7–8.

**Type consistency:** `Home.root/0`, `Home.bundle_dir/1`, `Home.bundles/0`; `Manifest.read/1` returns `{:ok, string-keyed map}`; `Pidfile.running?/1`; `Leases.lookup_ip/2` (lowercased MAC); command `run/1` + injectable `run/2` — names match across consumers (Ip/Ls/CLI). `CLI.run/1` return shape `{:ok, iodata} | {:error, code, iodata}` is consistent with both command modules.
