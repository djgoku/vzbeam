# Burrito Single-File Packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `vzbeam` as a single Apple-Silicon binary that needs no Elixir/Erlang/Swift toolchain and carries the ad-hoc-signed `vz` sidecar inside its payload.

**Architecture:** Burrito wraps the existing Elixir engine into a self-contained ERTS binary; an `Application.start/2` guarded by `Burrito.Util.Args.get_bin_path/0` runs the CLI only inside the wrapped release. A Burrito **patch-phase** step builds + ad-hoc-signs the Swift `vz` and drops it into the release payload's `priv/`; `Sidecar.locate/0` gains a guarded bundled-priv candidate. The escript stays for dev + `mix test`.

**Tech Stack:** Elixir `~> 1.17`, Burrito `~> 1.0` (v1.5.0), Zig 0.15.2 (via `mise.toml`), SwiftPM sidecar, `codesign` (ad-hoc).

**Spec:** `docs/superpowers/specs/2026-06-25-vzbeam-burrito-packaging-design.md`

## Global Constraints

_Every task implicitly includes these (verbatim from the spec):_

- **Build host AND target are both Apple-Silicon macOS.** Same-arch build (bundles the local ERTS; `swift build` follows the host toolchain). This box qualifies (`uname -m` = arm64).
- **Minimum macOS = 13 (Ventura)** — the sidecar's `Package.swift` floor (`.macOS(.v13)`).
- **Target is aarch64-only:** `macos_silicon: [os: :darwin, cpu: :aarch64]`. No Intel/Linux/Windows.
- **Ad-hoc signing only** (no notarization). Sidecar entitlement: `com.apple.security.virtualization` via `swift/vz.entitlements` (re-signed every build — swift drops it on relink).
- **Deliverable build command: `MIX_ENV=prod mix release`.** (`MIX_ENV != prod` always re-extracts — handy in the spike loop, not the shipped mode.)
- **`mix test` and `mix escript.build` stay green throughout.** No `Mix.*` on the engine's runtime path; no release runtime hooks (`env.sh`/`vm.args`/cookie/node).
- **This box CANNOT boot VZ guests** (no nested macOS virtualization). VM-boot validation is HW-gated to the real Mac (`dj_goku@10.5.0.48`); everything else is provable here.
- **Force a clean install between packaging iterations** (`./burrito_out/vzbeam maintenance uninstall`, or bump version) — Burrito reuses a content-addressed install keyed by name/version/ERTS and will otherwise run a stale extracted sidecar.

---

### Task 1: Burrito skeleton + guarded entrypoint (engine-only binary)

Adds the Burrito dependency, a release target, and the `Application.start/2` entrypoint that runs the CLI **only** inside a wrapped release. Produces a working single-file binary that has no sidecar yet (so VM ops will report "sidecar not found" — expected until Task 4).

**Files:**
- Modify: `mix.exs` (deps, `escript:`, `application/0`, add `releases/0`)
- Create: `lib/vzbeam/application.ex`
- Test: `test/application_test.exs`

**Interfaces:**
- Produces: `VzBeam.Application.cli_mode?/0 :: boolean`; `application/0` with `mod: {VzBeam.Application, []}`; `escript: [main_module: VzBeam.CLI, app: nil]`; `releases/0` (Burrito target, **no** `extra_steps` yet — Task 4 adds it).

- [ ] **Step 1: Add the Burrito dep and confirm it doesn't break the build**

Edit `mix.exs` `deps/0`:

```elixir
defp deps, do: [{:jason, "~> 1.4"}, {:burrito, "~> 1.0"}]
```

Run: `mix deps.get && mix compile`
Expected: resolves `burrito` (and its deps) and compiles clean. If `jason` conflicts, run `mix deps.get` and accept the compatible version Burrito requires.

- [ ] **Step 2: Write the failing entrypoint test**

Create `test/application_test.exs`:

```elixir
defmodule VzBeam.ApplicationTest do
  use ExUnit.Case, async: true

  test "cli_mode? is false outside a Burrito release (keeps mix test inert)" do
    refute VzBeam.Application.cli_mode?()
  end

  test "the inert supervisor is running under mix test" do
    assert is_pid(Process.whereis(VzBeam.Supervisor))
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `mix test test/application_test.exs`
Expected: FAIL — `VzBeam.Application` / `VzBeam.Supervisor` do not exist yet (UndefinedFunctionError / nil).

- [ ] **Step 4: Implement the entrypoint**

Create `lib/vzbeam/application.ex`:

```elixir
defmodule VzBeam.Application do
  @moduledoc false
  use Application

  # In a Burrito-wrapped release this process IS the CLI: read argv from the Zig
  # wrapper, run the command, halt. Everywhere else (mix test, iex -S mix, the
  # escript) get_bin_path/0 reports :not_in_burrito, so we stay an inert (empty)
  # supervisor and let VzBeam.CLI.main/1 drive instead.
  @impl true
  def start(_type, _args) do
    if cli_mode?() do
      VzBeam.CLI.main(Burrito.Util.Args.argv())
      System.halt(0)
    else
      Supervisor.start_link([], strategy: :one_for_one, name: VzBeam.Supervisor)
    end
  end

  @doc false
  @spec cli_mode?() :: boolean
  def cli_mode?, do: Burrito.Util.Args.get_bin_path() != :not_in_burrito
end
```

- [ ] **Step 5: Wire `mix.exs` (entrypoint, escript app-neutral, release target)**

Edit `mix.exs` — set `escript:`, add `releases: releases()`, give `application/0` a `mod:`, and add `releases/0`:

```elixir
  def project do
    [
      app: :vzbeam,
      version: "0.1.0",
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
        burrito: [targets: [macos_silicon: [os: :darwin, cpu: :aarch64]]]
      ]
    ]
  end
```

- [ ] **Step 6: Run the test suite — it passes and nothing regressed**

Run: `mix test`
Expected: PASS — the two new tests plus all existing tests green (the app now boots the inert supervisor during tests; `cli_mode?` is false because we're not in a wrapped release).

- [ ] **Step 7: Confirm the escript still builds and runs**

Run: `mix escript.build && ./vzbeam --help`
Expected: builds `./vzbeam`; `--help` prints the usage banner (escript unaffected by `app: nil`).

- [ ] **Step 8: Build and exercise the Burrito binary (argv + halt + cold-start)**

Run:
```bash
MIX_ENV=prod mix release
./burrito_out/vzbeam --help
./burrito_out/vzbeam ls
```
Expected: `mix release` produces `./burrito_out/vzbeam`; `--help` prints the **full** usage banner with no truncation (proves `IO.write` flushed before `System.halt/0`); `ls` runs the real command (argv plumbed through `Burrito.Util.Args.argv()`). A VM verb like `./burrito_out/vzbeam ip base` should report the sidecar isn't found — expected until Task 4.

Cold-start (record numbers, no hard SLA):
```bash
time ./burrito_out/vzbeam ls   # first run extracts (slow, one-time)
time ./burrito_out/vzbeam ls   # steady state
time ./vzbeam ls               # escript baseline
```
Expected: first run noticeably slower (extraction); steady-state comparable to the escript (both pay BEAM boot).

- [ ] **Step 9: Commit**

```bash
git add mix.exs mix.lock lib/vzbeam/application.ex test/application_test.exs
git commit -m "feat(burrito): wrap the engine into a single binary + guarded CLI entrypoint"
```

---

### Task 2: Shared sidecar build/sign helper (DRY)

Extracts the swift-build + ad-hoc-sign logic out of `Mix.Tasks.Vz.Build` into a reusable, runner-injectable helper so the release staging step (Task 4) and `mix vz.build` don't drift. Behavior change: build output is captured and shown on failure (instead of streamed live) — acceptable, and it makes the helper testable.

**Files:**
- Create: `lib/vzbeam/sidecar/build.ex`
- Modify: `lib/mix/tasks/vz.build.ex`
- Test: `test/sidecar_build_test.exs`

**Interfaces:**
- Produces: `VzBeam.Sidecar.Build.build_and_sign(swift_dir \\ "swift", runner \\ &System.cmd/3) :: {:ok, Path.t()} | {:error, String.t()}` — `runner` matches `System.cmd/3`.
- Consumes: nothing.

- [ ] **Step 1: Write the failing helper test**

Create `test/sidecar_build_test.exs`:

```elixir
defmodule VzBeam.Sidecar.BuildTest do
  use ExUnit.Case, async: true
  alias VzBeam.Sidecar.Build

  test "compiles, resolves the product path, and ad-hoc-signs it with the entitlement" do
    parent = self()

    runner = fn
      "swift", ["build", "-c", "release", "--package-path", "swift"], _opts ->
        send(parent, :compiled)
        {"", 0}

      "swift", ["build", "-c", "release", "--show-bin-path", "--package-path", "swift"], _opts ->
        {"/tmp/binpath\n", 0}

      "codesign", ["--force", "--sign", "-", "--entitlements", ent, product], _opts ->
        send(parent, {:signed, ent, product})
        {"", 0}
    end

    assert {:ok, "/tmp/binpath/vz"} = Build.build_and_sign("swift", runner)
    assert_received :compiled
    assert_received {:signed, "swift/vz.entitlements", "/tmp/binpath/vz"}
  end

  test "returns an error tuple when swift build fails" do
    runner = fn "swift", ["build", "-c", "release", "--package-path", _], _ -> {"", 65} end
    assert {:error, msg} = Build.build_and_sign("swift", runner)
    assert msg =~ "swift build"
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/sidecar_build_test.exs`
Expected: FAIL — `VzBeam.Sidecar.Build` does not exist.

- [ ] **Step 3: Implement the helper**

Create `lib/vzbeam/sidecar/build.ex`:

```elixir
defmodule VzBeam.Sidecar.Build do
  @moduledoc "Build + ad-hoc-sign (virtualization entitlement) the Swift `vz` sidecar."

  @swift "swift"

  @doc """
  Compile `swift/` in release mode and ad-hoc-sign the `vz` product with the
  virtualization entitlement (swift drops it on every relink, so re-sign every
  build). Returns the signed product path. `runner` matches `System.cmd/3`.
  """
  @spec build_and_sign(Path.t(), function()) :: {:ok, Path.t()} | {:error, String.t()}
  def build_and_sign(swift_dir \\ @swift, runner \\ &System.cmd/3) do
    with :ok <- compile(swift_dir, runner),
         {:ok, product} <- product_path(swift_dir, runner),
         :ok <- sign(swift_dir, product, runner) do
      {:ok, product}
    end
  end

  defp compile(swift_dir, runner) do
    {out, status} =
      runner.("swift", ["build", "-c", "release", "--package-path", swift_dir], stderr_to_stdout: true)

    if status == 0, do: :ok, else: {:error, "`swift build` failed (exit #{status}):\n#{out}"}
  end

  defp product_path(swift_dir, runner) do
    {out, status} =
      runner.("swift", ["build", "-c", "release", "--show-bin-path", "--package-path", swift_dir],
        stderr_to_stdout: true)

    if status == 0,
      do: {:ok, Path.join(String.trim(to_string(out)), "vz")},
      else: {:error, "`swift build --show-bin-path` failed (exit #{status}):\n#{out}"}
  end

  defp sign(swift_dir, product, runner) do
    ent = Path.join(swift_dir, "vz.entitlements")

    {out, status} =
      runner.("codesign", ["--force", "--sign", "-", "--entitlements", ent, product],
        stderr_to_stdout: true)

    if status == 0, do: :ok, else: {:error, "codesign failed (exit #{status}):\n#{out}"}
  end
end
```

- [ ] **Step 4: Run the helper test — passes**

Run: `mix test test/sidecar_build_test.exs`
Expected: PASS.

- [ ] **Step 5: Refactor `mix vz.build` to use the helper**

Replace `lib/mix/tasks/vz.build.ex` with:

```elixir
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
```

- [ ] **Step 6: Verify the suite is green and `mix vz.build` still works end-to-end**

Run:
```bash
mix test
mix vz.build
```
Expected: all tests green; `mix vz.build` compiles + signs + prints `vz installed -> .../bin/vz` (real swift build — this box has the toolchain).

- [ ] **Step 7: Commit**

```bash
git add lib/vzbeam/sidecar/build.ex lib/mix/tasks/vz.build.ex test/sidecar_build_test.exs
git commit -m "refactor(sidecar): extract shared build_and_sign/2 helper (DRY); vz.build uses it"
```

---

### Task 3: Guarded bundled-priv candidate + selected-path observability

Teaches `Sidecar.locate/0` to find the bundled `priv/vz`, guarded so the `:code.priv_dir/1` error tuple can never crash dev/escript, and surfaces the chosen path under `VZBEAM_DEBUG`.

**Files:**
- Modify: `lib/vzbeam/sidecar.ex` (`locate/0`, add `priv_vz/1`, add `debug/1`)
- Test: `test/sidecar_test.exs` (add cases)

**Interfaces:**
- Produces: `VzBeam.Sidecar.priv_vz/1 :: nil | Path.t()`; `locate/0` candidate order `VZBEAM_VZ → $VZBEAM_HOME/bin/vz → priv_vz(:code.priv_dir(:vzbeam)) → alongside → PATH`; `VZBEAM_DEBUG` stderr line `vzbeam: using sidecar <path>`.

- [ ] **Step 1: Write the failing tests**

Add to `test/sidecar_test.exs` (inside the module):

```elixir
  test "priv_vz/1 guards against :code.priv_dir error (no crash, yields nil)" do
    assert nil == Sidecar.priv_vz({:error, :bad_name})
  end

  test "priv_vz/1 joins the priv dir (charlist or binary) to vz" do
    assert "/x/vz" == Sidecar.priv_vz(~c"/x")
    assert "/x/vz" == Sidecar.priv_vz("/x")
  end

  test "VZBEAM_DEBUG announces the chosen sidecar path to stderr" do
    System.put_env("VZBEAM_DEBUG", "1")
    on_exit(fn -> System.delete_env("VZBEAM_DEBUG") end)
    err = ExUnit.CaptureIO.capture_io(:stderr, fn -> Sidecar.locate() end)
    assert err =~ "using sidecar #{@fake}"
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `mix test test/sidecar_test.exs`
Expected: FAIL — `Sidecar.priv_vz/1` undefined; no `VZBEAM_DEBUG` output.

- [ ] **Step 3: Implement the candidate, guard, and debug line**

In `lib/vzbeam/sidecar.ex`, replace `locate/0` and add the helpers:

```elixir
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
```

- [ ] **Step 4: Run the suite — passes, precedence preserved**

Run: `mix test test/sidecar_test.exs`
Expected: PASS — new cases green; existing `locate` tests still pass (`VZBEAM_VZ` still wins; the bundled candidate resolves to a non-existent `priv/vz` in dev and is skipped).

- [ ] **Step 5: Commit**

```bash
git add lib/vzbeam/sidecar.ex test/sidecar_test.exs
git commit -m "feat(sidecar): guarded bundled priv/vz candidate + VZBEAM_DEBUG path observability"
```

---

### Task 4: Sidecar staging via Burrito patch phase + integration validation

Builds + signs `vz` and drops it into the release payload via Burrito's **patch phase** (`work_dir` is the directory Burrito archives), then proves on this box that the bundled sidecar extracts intact (short of actually booting a VM).

**Files:**
- Create: `lib/vzbeam/release.ex`
- Modify: `mix.exs` (`releases/0` → add `extra_steps`)

**Interfaces:**
- Consumes: `VzBeam.Sidecar.Build.build_and_sign/2` (Task 2); the `releases/0` target (Task 1); the guarded priv candidate (Task 3).
- Produces: `VzBeam.Release.stage_sidecar/1` (Burrito patch step: map with `:work_dir` in, same map out).

- [ ] **Step 1: Discovery — confirm the patch-step contract**

Create `lib/vzbeam/release.ex` with a temporary inspecting step:

```elixir
defmodule VzBeam.Release do
  @moduledoc false
  def stage_sidecar(context) do
    IO.inspect(Map.take(context, [:work_dir, :self_dir]), label: "burrito ctx")
    IO.inspect(Path.wildcard(Path.join(context.work_dir, "lib/vzbeam-*")), label: "app dirs")
    context
  end
end
```

Wire it in `mix.exs` `releases/0`:

```elixir
      burrito: [
        targets: [macos_silicon: [os: :darwin, cpu: :aarch64]],
        extra_steps: [patch: [post: [&VzBeam.Release.stage_sidecar/1]]]
      ]
```

Run: `MIX_ENV=prod mix release`
Expected: logs a `burrito ctx` map with a real `:work_dir`, and `app dirs` listing exactly one `.../lib/vzbeam-0.1.0` path. (Confirms the field name + that the patch step receives/returns the context.)

- [ ] **Step 2: Implement real staging**

Replace `lib/vzbeam/release.ex`:

```elixir
defmodule VzBeam.Release do
  @moduledoc false

  # Burrito patch-phase step: build + ad-hoc-sign the Swift `vz` and drop it into
  # the release payload's priv/ so :code.priv_dir(:vzbeam) resolves it at runtime.
  # work_dir is the directory Burrito archives. Receives + returns the context.
  def stage_sidecar(%{work_dir: work_dir} = context) do
    product =
      case VzBeam.Sidecar.Build.build_and_sign() do
        {:ok, p} -> p
        {:error, m} -> raise "vz sidecar staging failed: #{m}"
      end

    [app_dir] = Path.wildcard(Path.join(work_dir, "lib/vzbeam-*"))
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
```

- [ ] **Step 3: Build the single-file binary with a clean install**

Run:
```bash
rm -rf burrito_out
MIX_ENV=prod mix release
```
Expected: the `burrito: staged signed vz -> .../lib/vzbeam-0.1.0/priv/vz (sha256=<HASH>)` line appears; `./burrito_out/vzbeam` is produced. **Record `<HASH>`** for Step 5.

- [ ] **Step 4: Force a clean extraction, then confirm the bundled sidecar is selected**

Run:
```bash
./burrito_out/vzbeam maintenance uninstall   # clear any prior content-addressed install
unset VZBEAM_VZ; unset VZBEAM_HOME           # don't let a dev sidecar shadow the bundle
VZBEAM_DEBUG=1 ./burrito_out/vzbeam ls 2>&1 | grep "using sidecar"
```
Expected: extraction happens; the debug line shows `using sidecar <install>/lib/vzbeam-0.1.0/priv/vz` — the **bundled** path, not a `$VZBEAM_HOME/bin/vz`.

- [ ] **Step 5: Prove the extracted sidecar is intact — runs, byte-identical, entitled**

Run:
```bash
DIR=$(./burrito_out/vzbeam maintenance directory)
VZ="$DIR"/lib/vzbeam-0.1.0/priv/vz
"$VZ" --version                               # protocol handshake; no entitlement needed to run
shasum -a 256 "$VZ"                           # compare to <HASH> from Step 3 — must match
codesign -d --entitlements - "$VZ" 2>&1 | grep -A1 virtualization
test -x "$VZ" && echo "exec bit OK"
```
Expected: `--version` prints the version/protocol JSON; the sha256 **equals** Step 3's `<HASH>` (extraction preserved bytes); `codesign` shows `com.apple.security.virtualization`; the exec bit is set. (If the exec bit is missing, the defensive `chmod` in `locate/0`/staging covers it — note it for Step 6 of Task 5.)

- [ ] **Step 6: Commit**

```bash
git add lib/vzbeam/release.ex mix.exs
git commit -m "feat(burrito): stage ad-hoc-signed vz into the payload via the patch phase"
```

---

### Task 5: Distribution hardening — wrapper signing, quarantine, docs

Resolves the wrapper-signing/quarantine questions with evidence, then writes the user-facing docs and ignores the build output. May produce a post-`wrap` signing step (only if the evidence demands it) — otherwise it's documentation.

**Files:**
- Modify: `.gitignore` (add `/burrito_out/`)
- Modify: `README.md` (packaging section)
- Modify: `docs/superpowers/specs/2026-06-21-vzbeam-design.md` (§11 note)
- Possibly modify: `mix.exs` / `lib/vzbeam/release.ex` (post-`wrap` ad-hoc sign — only if Step 1/2 require it)

**Interfaces:**
- Consumes: the wrapped binary from Task 4.

- [ ] **Step 1: Evidence — does the wrapper run, and is it signed?**

Run:
```bash
codesign -dv ./burrito_out/vzbeam 2>&1 | grep -E "Signature|flags" || echo "UNSIGNED"
./burrito_out/vzbeam --help >/dev/null && echo "wrapper runs"
```
Expected: the wrapper runs (it already did in Task 1). Note whether Zig left an ad-hoc signature. If it runs and is signed → no wrapper-signing code needed.

- [ ] **Step 2: Evidence — quarantine inheritance on the scp/local channel**

Run:
```bash
xattr -p com.apple.quarantine ./burrito_out/vzbeam 2>&1 || echo "no quarantine (expected for local/scp)"
# Simulate a quarantined download and check whether the EXTRACTED sidecar inherits it:
cp ./burrito_out/vzbeam /tmp/vzbeam-q && xattr -w com.apple.quarantine "0081;0;test;" /tmp/vzbeam-q
/tmp/vzbeam-q maintenance uninstall; /tmp/vzbeam-q ls >/dev/null 2>&1 || true
DIR=$(/tmp/vzbeam-q maintenance directory)
xattr -p com.apple.quarantine "$DIR"/lib/vzbeam-0.1.0/priv/vz 2>&1 || echo "extracted vz: no quarantine"
```
Expected (record actual): locally-built binary has **no** quarantine. Document whether a quarantined wrapper propagates quarantine to the extracted `vz`.

- [ ] **Step 3: Decide + implement only if needed**

- If Step 1 shows the wrapper is unsigned or won't run on a clean machine → add a post-`wrap` step that ad-hoc-signs the wrapper (`codesign --force --sign - <binary>`) and re-verify it runs. Otherwise, **no code change**.
- If Step 2 shows the extracted `vz` inherits quarantine → the README `xattr -dr` instruction (Step 4) is the fix; do **not** add programmatic xattr-stripping unless boot validation (Task 6) proves it necessary (YAGNI).

Record the decision in one line in the commit message.

- [ ] **Step 4: Document packaging in the README**

Add this section to `README.md` (after "Build, test, run"):

```markdown
## Packaging a single-file binary (Burrito)

Produce one self-contained `vzbeam` for Apple-Silicon macOS (≥ 13) — no Elixir/Erlang/Swift
needed on the target. The ad-hoc-signed `vz` sidecar rides inside the binary's payload.

Requires Zig 0.15.2 (pinned in `mise.toml`) and the Swift toolchain on the **build** Mac:

```sh
MIX_ENV=prod mix release         # -> ./burrito_out/vzbeam  (carries the signed vz)
scp ./burrito_out/vzbeam user@mac:/usr/local/bin/vzbeam
```

Copying via `scp`/`rsync`/`tar` adds no quarantine, so the ad-hoc-signed binary runs as-is.
If you download it via a browser/AirDrop, clear quarantine once before first run:

```sh
xattr -dr com.apple.quarantine ./vzbeam
```

`VZBEAM_DEBUG=1 vzbeam <cmd>` prints which `vz` sidecar was selected. The bundled sidecar is
overridable by `$VZBEAM_VZ` or a `mix vz.build` install in `$VZBEAM_HOME/bin/vz`.
```

- [ ] **Step 5: Ignore the build output + record the parent-spec decision**

Add to `.gitignore`:

```
# Burrito release output
/burrito_out/
```

In `docs/superpowers/specs/2026-06-21-vzbeam-design.md` §11, append one line under the entitlement-split paragraph:

```markdown
> **Delivered (2026-06):** the "two artifacts" ship as **one file** — `vz` rides ad-hoc-signed in the
> Burrito payload's `priv/` (its own signature; the wrapper never signs it). See
> `specs/2026-06-25-vzbeam-burrito-packaging-design.md`.
```

- [ ] **Step 6: Verify + commit**

Run: `mix test`
Expected: green (no engine changes, or wrapper-signing step only).

```bash
git add .gitignore README.md docs/superpowers/specs/2026-06-21-vzbeam-design.md mix.exs lib/vzbeam/release.ex
git commit -m "docs(burrito): packaging README + quarantine/signing decision; ignore burrito_out"
```

---

### Task 6: HW-gated VM-boot validation (run on the Mac)

**This task cannot run on the build host** (no nested macOS virtualization). Execute it on real Apple Silicon (`dj_goku@10.5.0.48`) and record results. It is the only step that proves a VM actually boots from the bundled sidecar; Tasks 4–5 already proved everything short of boot.

**Files:**
- Create: `docs/superpowers/results/2026-06-26-vzbeam-burrito-hw.md`

- [ ] **Step 1: Ship the binary to the Mac**

```bash
scp ./burrito_out/vzbeam dj_goku@10.5.0.48:~/vzbeam
ssh dj_goku@10.5.0.48 'xattr -p com.apple.quarantine ~/vzbeam || echo "no quarantine"'
```
Expected: no quarantine over scp; the binary is present.

- [ ] **Step 2: Boot a guest from the bundled sidecar**

On the Mac (against an existing provisioned base):
```bash
VZBEAM_DEBUG=1 ~/vzbeam ls                 # confirms it selects the bundled priv/vz
~/vzbeam run <base> --headless
~/vzbeam ip <base> && ~/vzbeam ssh <base> -- true
~/vzbeam kill <base>
```
Expected: `run` boots (no entitlement/signature error from the extracted `vz`), SSH succeeds, `kill` stops it. A `--gui` smoke test is optional.

- [ ] **Step 3: Record results + commit**

Write `docs/superpowers/results/2026-06-26-vzbeam-burrito-hw.md` with: macOS version, the selected sidecar path, the four command outcomes, and any quarantine/signing notes. Commit:

```bash
git add docs/superpowers/results/2026-06-26-vzbeam-burrito-hw.md
git commit -m "test(burrito): HW validation — VM boots from the bundled sidecar"
```

---

## Self-Review

**Spec coverage:** §1 support matrix → Global Constraints + Task 6; §2 scope → Tasks 1–5; §3 shape/reuse → Tasks 4 (staging) + clean-install constraint; §4 mix.exs → Tasks 1 (deps/escript/app/releases) + 4 (extra_steps); §5 entrypoint → Task 1; §6 staging → Tasks 2 (helper) + 4 (patch step); §7 locate/observability → Task 3; §8 signing/quarantine → Task 5; §9 validation → Tasks 1 (cold-start), 4 (extraction/byte-identity/entitlement), 5 (wrapper/quarantine), 6 (boot); §10 decisions + §11 open questions → resolved across Tasks 4–6. No gaps.

**Placeholders:** none — every code/test/command step is concrete. Task 5 Step 3 is intentionally conditional (evidence-gated), with both branches specified.

**Type consistency:** `build_and_sign/2` returns `{:ok, Path.t()} | {:error, String.t()}` and is consumed identically in `Mix.Tasks.Vz.Build` and `VzBeam.Release.stage_sidecar/1`. `priv_vz/1` returns `nil | Path.t()`, consumed by `locate/0`'s `usable?/1` (already nil-safe). `cli_mode?/0 :: boolean`. `stage_sidecar/1` takes/returns the context map. Consistent across tasks.
