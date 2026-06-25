# vzbeam `set` + `displays` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `vzbeam set <name> [--cpu N] [--mem-gb M]` to edit a stopped VM's CPU/RAM, and `vzbeam displays` to show the host display(s) with suggested `--resolution` values.

**Architecture:** Both are engine-only. `set` reads/rewrites the bundle's `config.json` via a shared `Manifest.write_to/2`. `displays` shells `system_profiler SPDisplaysDataType -json`, parsed by a pure `VzBeam.Displays` module. No Swift sidecar change, no wire-protocol change.

**Tech Stack:** Elixir (OptionParser, Jason), `system_profiler` (macOS).

## Global Constraints

- Verb contract: `{:ok, iodata} | {:error, non_neg_integer, iodata}`. Exit codes: **2** = usage/unknown-or-bad-flag, **1** = runtime failure.
- No new dependencies. Do **not** touch `swift/` or the wire protocol.
- `mix test` and `mix compile --force --warnings-as-errors` must stay clean after every task.
- Memory is stored as `memoryBytes` (bytes); the friendly unit is GiB (`1024*1024*1024`).
- Build order: **Phase 1 (Tasks 1–2, `set`)** is green-bucket — ship without a Mac. **Phase 2 (Tasks 3–6, `displays`)** is HW-gated — needs a release-macOS Apple Silicon Mac.

## File Structure

- `lib/vzbeam/manifest.ex` — gains `write_to/2` (shared atomic, schema-stamped writer).
- `lib/vzbeam/commands/new.ex` — routed through `Manifest.write_to/2`.
- `lib/vzbeam/commands/set.ex` — new `set` verb (cpu/mem edit).
- `lib/vzbeam/displays.ex` — new pure module: parse `system_profiler` JSON + suggest resolutions.
- `lib/vzbeam/commands/displays.ex` — new `displays` verb (shells `system_profiler`, formats output).
- `lib/vzbeam/cli.ex` — dispatch + usage for both verbs.
- `test/support/displays_fixture.json` — real `system_profiler` output captured on the Mac (Task 3).

---

## Phase 1 — `set` (green-bucket)

### Task 1: Extract `Manifest.write_to/2`; route `new` through it

**Files:**
- Modify: `lib/vzbeam/manifest.ex`
- Modify: `lib/vzbeam/commands/new.ex`
- Test: `test/manifest_test.exs`

**Interfaces:**
- Produces: `Manifest.write_to(path :: Path.t(), map :: map) :: :ok | {:error, term}` — atomic write of a config.json that has `"schemaVersion"` stamped in.

- [ ] **Step 1: Write the failing test** — append to `test/manifest_test.exs` before the final `end`:

```elixir
  test "write_to stamps schemaVersion and round-trips via read" do
    :ok = VzBeam.Manifest.write_to(VzBeam.Manifest.path("base"), %{"name" => "base", "macAddress" => "5e:aa"})
    assert {:ok, %{"name" => "base", "macAddress" => "5e:aa", "schemaVersion" => 1}} =
             VzBeam.Manifest.read("base")
  end
```

- [ ] **Step 2: Run it, verify it fails**

Run: `mix test test/manifest_test.exs`
Expected: FAIL — `function VzBeam.Manifest.write_to/2 is undefined`.

- [ ] **Step 3: Implement `write_to/2`** — edit `lib/vzbeam/manifest.ex`: update the moduledoc, alias, add `@schema_version`, and add `write_to/2`:

```elixir
defmodule VzBeam.Manifest do
  @moduledoc "Read/write a bundle's config.json (atomic, schema-stamped)."
  alias VzBeam.{Home, AtomicFile}

  @schema_version 1
```

and add, after `read_or/2`:

```elixir
  @spec write_to(Path.t(), map) :: :ok | {:error, term}
  def write_to(path, map) do
    AtomicFile.write(path, Jason.encode!(Map.put(map, "schemaVersion", @schema_version), pretty: true))
  end
```

- [ ] **Step 4: Route `new` through it** — in `lib/vzbeam/commands/new.ex`: remove the `@schema_version 1` attribute line, drop `AtomicFile` from the alias (`alias VzBeam.{Home, Manifest, Pidfile, Cache, Defaults}`), and replace `write_manifest/2`:

```elixir
  defp write_manifest(dir, map) do
    Manifest.write_to(Path.join(dir, "config.json"), map)
  end
```

- [ ] **Step 5: Run tests + warnings**

Run: `mix test && mix compile --force --warnings-as-errors`
Expected: all pass (incl. existing `new` tests), no warnings (AtomicFile no longer aliased in `new`).

- [ ] **Step 6: Commit**

```bash
git add lib/vzbeam/manifest.ex lib/vzbeam/commands/new.ex test/manifest_test.exs
git commit -m "refactor(manifest): shared write_to/2; route new through it"
```

---

### Task 2: `set` verb + CLI wiring

**Files:**
- Create: `lib/vzbeam/commands/set.ex`
- Modify: `lib/vzbeam/cli.ex`
- Test: `test/commands/set_test.exs`, `test/cli_test.exs`

**Interfaces:**
- Consumes: `Manifest.read_or/2`, `Manifest.write_to/2` (Task 1), `Pidfile.running?/1`.
- Produces: `VzBeam.Commands.Set.run(args :: [String.t()])`.

- [ ] **Step 1: Write the failing test** — create `test/commands/set_test.exs`:

```elixir
defmodule VzBeam.Commands.SetTest do
  use ExUnit.Case, async: false
  alias VzBeam.Commands.Set

  @gb 1024 * 1024 * 1024

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-set-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    File.mkdir_p!(Path.join(home, "dev"))
    File.write!(Path.join([home, "dev", "config.json"]),
      Jason.encode!(%{"name" => "dev", "cpuCount" => 4, "memoryBytes" => 8 * @gb,
                      "macAddress" => "5e:aa", "machineIdentifier" => "MID"}))
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    {:ok, home: home}
  end

  defp manifest(home), do: Jason.decode!(File.read!(Path.join([home, "dev", "config.json"])))

  test "sets cpu and mem, preserving other keys", %{home: home} do
    assert {:ok, msg} = Set.run(["dev", "--cpu", "8", "--mem-gb", "16"])
    assert IO.iodata_to_binary(msg) =~ "cpu=8 mem=16G"
    m = manifest(home)
    assert m["cpuCount"] == 8 and m["memoryBytes"] == 16 * @gb and m["macAddress"] == "5e:aa"
  end

  test "cpu-only leaves mem unchanged and still prints both", %{home: home} do
    assert {:ok, msg} = Set.run(["dev", "--cpu", "2"])
    assert IO.iodata_to_binary(msg) =~ "cpu=2 mem=8G"
    assert manifest(home)["memoryBytes"] == 8 * @gb
  end

  test "refuses a running VM" do
    :ok = VzBeam.Pidfile.write("dev", System.pid())
    assert {:error, 1, msg} = Set.run(["dev", "--cpu", "2"])
    assert IO.iodata_to_binary(msg) =~ "running"
  end

  test "errors on a missing bundle" do
    assert {:error, 1, msg} = Set.run(["ghost", "--cpu", "2"])
    assert IO.iodata_to_binary(msg) =~ "no such bundle"
  end

  test "usage (exit 2) on no-flags, extra positional, bad-typed, unknown flag, sub-1 values" do
    assert {:error, 2, _} = Set.run(["dev"])
    assert {:error, 2, _} = Set.run(["dev", "extra", "--cpu", "2"])
    assert {:error, 2, _} = Set.run(["dev", "--cpu", "nope"])
    assert {:error, 2, _} = Set.run(["dev", "--bogus"])
    assert {:error, 2, _} = Set.run(["dev", "--cpu", "0"])
    assert {:error, 2, _} = Set.run(["dev", "--mem-gb", "0"])
  end

  test "mem-only leaves cpu unchanged and still prints both", %{home: home} do
    assert {:ok, msg} = Set.run(["dev", "--mem-gb", "16"])
    assert IO.iodata_to_binary(msg) =~ "cpu=4 mem=16G"
    assert manifest(home)["cpuCount"] == 4
  end

  test "surfaces a write failure as exit 1", %{home: home} do
    dir = Path.join(home, "dev")
    File.chmod!(dir, 0o500)                     # no write -> the atomic write fails
    on_exit(fn -> File.chmod(dir, 0o700) end)   # restore so setup's rm_rf can clean up
    assert {:error, 1, msg} = Set.run(["dev", "--cpu", "2"])
    assert IO.iodata_to_binary(msg) =~ "set failed"
  end
end
```

- [ ] **Step 2: Run it, verify it fails**

Run: `mix test test/commands/set_test.exs`
Expected: FAIL — `VzBeam.Commands.Set` is undefined.

- [ ] **Step 3: Implement `set`** — create `lib/vzbeam/commands/set.ex`:

```elixir
defmodule VzBeam.Commands.Set do
  @moduledoc "set <name> [--cpu N] [--mem-gb M] — change a stopped VM's CPU/RAM."
  alias VzBeam.{Manifest, Pidfile}

  @gb 1024 * 1024 * 1024

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: [cpu: :integer, mem_gb: :integer])

    cond do
      invalid != [] -> {:error, 2, "set: invalid option\n"}
      not match?([_], positional) or opts == [] -> usage()
      true -> apply_set(hd(positional), opts)
    end
  end

  defp apply_set(name, opts) do
    with :ok <- validate(opts),
         {:ok, m} <- Manifest.read_or(name, :no_such_bundle),
         :ok <- refute_running(name),
         updated = update(m, opts),
         :ok <- Manifest.write_to(Manifest.path(name), updated) do
      {:ok, ["set ", name, ": cpu=", to_string(updated["cpuCount"]),
             " mem=", to_string(div(updated["memoryBytes"], @gb)), "G\n"]}
    else
      err -> error(name, err)
    end
  end

  defp validate(opts) do
    cond do
      is_integer(opts[:cpu]) and opts[:cpu] < 1 -> {:error, :bad_cpu}
      is_integer(opts[:mem_gb]) and opts[:mem_gb] < 1 -> {:error, :bad_mem}
      true -> :ok
    end
  end

  defp update(m, opts) do
    m
    |> maybe_put("cpuCount", opts[:cpu])
    |> maybe_put("memoryBytes", opts[:mem_gb] && opts[:mem_gb] * @gb)
  end

  defp maybe_put(m, _key, nil), do: m
  defp maybe_put(m, key, val), do: Map.put(m, key, val)

  defp refute_running(name), do: if(Pidfile.running?(name), do: {:error, :running}, else: :ok)
  defp usage, do: {:error, 2, "usage: vzbeam set <name> [--cpu N] [--mem-gb M]\n"}

  defp error(_n, {:error, :no_such_bundle}), do: {:error, 1, "set: no such bundle\n"}
  defp error(name, {:error, :running}), do: {:error, 1, ["set: ", name, " is running; stop it first\n"]}
  defp error(_n, {:error, :bad_cpu}), do: {:error, 2, "set: --cpu must be >= 1\n"}
  defp error(_n, {:error, :bad_mem}), do: {:error, 2, "set: --mem-gb must be >= 1\n"}
  defp error(_n, {:error, reason}), do: {:error, 1, ["set failed: ", inspect(reason), "\n"]}
end
```

- [ ] **Step 4: Wire the CLI** — in `lib/vzbeam/cli.ex`, add a dispatch clause after the `new` clause:

```elixir
  def run(["set" | rest]), do: VzBeam.Commands.Set.run(rest)
```

and add to the `@usage` Commands block (after the `rm` line):

```
    set <name> [--cpu N] [--mem-gb M]  change a stopped VM's CPU/RAM
```

- [ ] **Step 5: Add the CLI test** — append to `test/cli_test.exs` before the final `end`:

```elixir
  test "set dispatches (usage error without flags) and appears in help" do
    assert {:error, 2, _} = VzBeam.CLI.run(["set", "dev"])
    assert IO.iodata_to_binary(elem(VzBeam.CLI.run(["--help"]), 1)) =~ "set <name>"
  end
```

- [ ] **Step 6: Run tests + warnings + escript smoke**

Run: `mix test && mix compile --force --warnings-as-errors && mix escript.build`
Then: `VZBEAM_HOME=$(mktemp -d) ./vzbeam set ghost --cpu 2` → expect `set: no such bundle` (exit 1).
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add lib/vzbeam/commands/set.ex lib/vzbeam/cli.ex test/commands/set_test.exs test/cli_test.exs
git commit -m "feat(set): edit a stopped VM's cpu/mem"
```

---

## Phase 2 — `displays` (HW-gated)

### Task 3: Spike — capture the `system_profiler` fixture on the Mac

**Files:**
- Create: `test/support/displays_fixture.json`

- [ ] **Step 1: Capture** — on the release Mac (over SSH), run and save into the repo:

```bash
system_profiler SPDisplaysDataType -json > test/support/displays_fixture.json
```

- [ ] **Step 2: Confirm the schema** — open the JSON and verify the path used by Task 4:
  `SPDisplaysDataType[*].spdisplays_ndrvs[*]`, with `_name`, `_spdisplays_pixels` (e.g. `"3024 x 1964"`),
  `_spdisplays_resolution` (the scaled/refresh string), and `spdisplays_main == "spdisplays_yes"` on the
  main display. **If any field name differs, note it — Task 4's parser must match the real keys.**

- [ ] **Step 3: Commit the fixture**

```bash
git add test/support/displays_fixture.json
git commit -m "test(displays): capture real system_profiler -json fixture (Mac)"
```

---

### Task 4: `VzBeam.Displays` — parse + suggestions

**Files:**
- Create: `lib/vzbeam/displays.ex`
- Test: `test/displays_test.exs`

**Interfaces:**
- Consumes: `test/support/displays_fixture.json` (Task 3).
- Produces: `Displays.parse(json :: String.t()) :: [display]` where `display = %{name: String.t(), width: pos_integer, height: pos_integer, main: boolean, looks_like: String.t() | nil}`; `Displays.suggestions(displays :: [display]) :: [String.t()]`.

- [ ] **Step 1: Write the failing test** — create `test/displays_test.exs` (uses the real fixture + inline edge cases):

```elixir
defmodule VzBeam.DisplaysTest do
  use ExUnit.Case, async: true
  alias VzBeam.Displays

  @fixture File.read!(Path.expand("support/displays_fixture.json", __DIR__))

  test "parses the captured fixture into at least one display with native pixels" do
    [d | _] = Displays.parse(@fixture)
    assert is_binary(d.name) and d.width > 0 and d.height > 0
  end

  test "suggestions: native, half, and the vzbeam default, deduped" do
    displays = [%{name: "X", width: 3024, height: 1964, main: true, looks_like: nil}]
    assert Displays.suggestions(displays) == ["3024x1964", "1512x982", "1920x1200"]
  end

  test "no displays -> just the default suggestion" do
    assert Displays.suggestions([]) == ["1920x1200"]
  end

  test "parse tolerates garbage, no SPDisplaysDataType, and pixel-less entries" do
    assert Displays.parse("not json") == []
    assert Displays.parse(~s({"other":1})) == []
    assert Displays.parse(~s({"SPDisplaysDataType":[{"spdisplays_ndrvs":[{"_name":"No Pixels"}]}]})) == []
  end
end
```

- [ ] **Step 2: Run it, verify it fails**

Run: `mix test test/displays_test.exs`
Expected: FAIL — `VzBeam.Displays` is undefined.

- [ ] **Step 3: Implement** — create `lib/vzbeam/displays.ex` (adjust field names to match the Task 3 fixture if they differ):

```elixir
defmodule VzBeam.Displays do
  @moduledoc "Parse `system_profiler SPDisplaysDataType -json` and suggest --resolution values."

  @default "1920x1200"
  @type display :: %{name: String.t(), width: pos_integer, height: pos_integer,
                     main: boolean, looks_like: String.t() | nil}

  @spec parse(String.t()) :: [display]
  def parse(json) do
    case Jason.decode(json) do
      {:ok, %{"SPDisplaysDataType" => gpus}} when is_list(gpus) ->
        gpus
        |> Enum.flat_map(&Map.get(&1, "spdisplays_ndrvs", []))
        |> Enum.map(&one/1)
        |> Enum.reject(&is_nil/1)

      _ -> []
    end
  end

  defp one(%{"_spdisplays_pixels" => px} = d) do
    case dims(px) do
      {w, h} -> %{name: d["_name"] || "Display", width: w, height: h,
                  main: d["spdisplays_main"] == "spdisplays_yes", looks_like: d["_spdisplays_resolution"]}
      :error -> nil
    end
  end
  defp one(_), do: nil

  defp dims(s) do
    case Regex.run(~r/(\d+)\s*x\s*(\d+)/, to_string(s)) do
      [_, w, h] -> {String.to_integer(w), String.to_integer(h)}
      _ -> :error
    end
  end

  @spec suggestions([display]) :: [String.t()]
  def suggestions([]), do: [@default]
  def suggestions(displays) do
    %{width: w, height: h} = Enum.find(displays, hd(displays), & &1.main)
    Enum.uniq(["#{w}x#{h}", "#{div(w, 2)}x#{div(h, 2)}", @default])
  end
end
```

- [ ] **Step 4: Run it, verify it passes**

Run: `mix test test/displays_test.exs && mix compile --force --warnings-as-errors`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/displays.ex test/displays_test.exs
git commit -m "feat(displays): parse system_profiler json + suggest resolutions"
```

---

### Task 5: `displays` verb + CLI wiring

**Files:**
- Create: `lib/vzbeam/commands/displays.ex`
- Modify: `lib/vzbeam/cli.ex`
- Test: `test/commands/displays_test.exs`, `test/cli_test.exs`

**Interfaces:**
- Consumes: `Displays.parse/1`, `Displays.suggestions/1` (Task 4).
- Produces: `VzBeam.Commands.Displays.run(args)` and `run(args, profiler)` where `profiler :: (-> String.t())`.

- [ ] **Step 1: Write the failing test** — create `test/commands/displays_test.exs`:

```elixir
defmodule VzBeam.Commands.DisplaysTest do
  use ExUnit.Case, async: true
  alias VzBeam.Commands.Displays

  @json ~s({"SPDisplaysDataType":[{"spdisplays_ndrvs":[{"_name":"Color LCD","_spdisplays_pixels":"3024 x 1964","_spdisplays_resolution":"1512 x 982 @ 120.00Hz","spdisplays_main":"spdisplays_yes"}]}]})

  test "prints the display and suggested resolutions" do
    assert {:ok, out} = Displays.run([], fn -> @json end)
    s = IO.iodata_to_binary(out)
    assert s =~ "Color LCD" and s =~ "3024 x 1964" and s =~ "suggested --resolution"
    assert s =~ "3024x1964" and s =~ "1920x1200"
  end

  test "no display -> friendly fallback, exit 0" do
    assert {:ok, out} = Displays.run([], fn -> "" end)
    assert IO.iodata_to_binary(out) =~ "no display detected"
  end

  test "rejects extra args (exit 2), consistent with other verbs" do
    assert {:error, 2, _} = Displays.run(["extra"], fn -> @json end)
  end
end
```

- [ ] **Step 2: Run it, verify it fails**

Run: `mix test test/commands/displays_test.exs`
Expected: FAIL — `VzBeam.Commands.Displays` is undefined.

- [ ] **Step 3: Implement** — create `lib/vzbeam/commands/displays.ex`:

```elixir
defmodule VzBeam.Commands.Displays do
  @moduledoc "displays — show host display(s) and suggested --resolution values."
  alias VzBeam.Displays

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run(args), do: run(args, &profiler/0)

  def run([], profiler) do
    case Displays.parse(profiler.()) do
      [] -> {:ok, "no display detected; vzbeam default is 1920x1200\n"}
      displays -> {:ok, [Enum.map(displays, &line/1), suggest(displays)]}
    end
  end

  def run(_args, _profiler), do: {:error, 2, "usage: vzbeam displays\n"}

  defp line(%{name: n, width: w, height: h} = d) do
    looks = if d.looks_like, do: ["   (looks like ", d.looks_like, ")"], else: []
    [n, "   ", to_string(w), " x ", to_string(h), " native", looks, "\n"]
  end

  defp suggest(displays) do
    ["suggested --resolution:\n" | Enum.map(Displays.suggestions(displays), &["  ", &1, "\n"])]
  end

  defp profiler do
    case System.cmd("system_profiler", ["SPDisplaysDataType", "-json"], stderr_to_stdout: true) do
      {out, 0} -> out
      _ -> ""
    end
  end
end
```

- [ ] **Step 4: Wire the CLI** — in `lib/vzbeam/cli.ex`, add a dispatch clause after the `ssh` clause:

```elixir
  def run(["displays" | rest]), do: VzBeam.Commands.Displays.run(rest)
```

and add to the `@usage` Commands block (after the `run` line):

```
    displays           show host display(s) + suggested --resolution values
```

- [ ] **Step 5: Add the CLI test** — append to `test/cli_test.exs` before the final `end`:

```elixir
  test "displays dispatches (arity guard) and appears in help" do
    assert {:error, 2, _} = VzBeam.CLI.run(["displays", "extra"])  # routed to the verb, not help
    assert IO.iodata_to_binary(elem(VzBeam.CLI.run(["--help"]), 1)) =~ "displays"
  end
```

- [ ] **Step 6: Run tests + warnings**

Run: `mix test && mix compile --force --warnings-as-errors`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add lib/vzbeam/commands/displays.ex lib/vzbeam/cli.ex test/commands/displays_test.exs test/cli_test.exs
git commit -m "feat(displays): verb that lists host displays + suggested resolutions"
```

---

### Task 6: Validate `displays` live on the Mac

- [ ] **Step 1: Build + run on the Mac** — rsync the tree to the release Mac, then:

```bash
mise exec -- mix escript.build && ./vzbeam displays
```

- [ ] **Step 2: Confirm** the output lists the Mac's real display(s) with native pixels and a suggested
  `--resolution` set, and that `vzbeam run <name> --resolution <suggested>` boots at that resolution.

- [ ] **Step 3: Record** the result in `docs/superpowers/results/` (a short note; reuse or add to the
  dated results file). Commit.

---

## Self-review notes

- **Spec coverage:** `set` (Tasks 1–2), shared writer (Task 1), `displays` detection/parse/suggest/CLI
  (Tasks 3–5), Mac validation (Task 6), all CLI/error-code rules, and every spec test case are covered.
- **Phase split:** Tasks 1–2 are fully green-bucket; Tasks 3–6 require the Mac (Task 3 captures the fixture
  the green-bucket Tasks 4–5 build against).
- **Risk:** the only schema dependency is `system_profiler`'s JSON keys — isolated to `Displays.parse/1`
  and defended (tolerates missing fields → `[]` → friendly fallback). The Task-3 manual schema check is the
  primary guard; the captured fixture then exercises the parser, and Task 6 confirms live on the Mac.
