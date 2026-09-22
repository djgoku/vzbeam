# OpenBSD ISO Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add interactive OpenBSD 7.9+ ARM64 installation, normal boot, and cached or one-shot ISO recovery while preserving the existing macOS lifecycle.

**Architecture:** The Elixir engine owns guest policy, schema normalization, ISO retention, CLI parsing, and lifecycle decisions. The Swift sidecar owns guest-specific Virtualization.framework configuration through separate Mac and generic-EFI builders, with protocol version 2 carrying install and identity events. The slices are ordered so every commit has a runnable Elixir suite and a compile-valid Swift sidecar.

**Tech Stack:** Elixir 1.20/OTP 29, ExUnit, Jason, Swift 6/SwiftPM, AppKit, and Apple's Virtualization.framework on Apple Silicon macOS 13 or newer.

**Spec:** `docs/superpowers/specs/2026-09-21-openbsd-iso-support-design.md`

## Global Constraints

- OpenBSD support targets ARM64 OpenBSD 7.9 or newer and accepts a local regular ISO file only.
- `vzbeam new NAME --iso PATH` is interactive, opens a GUI, and completes only after the guest powers off with `halt -p`.
- `vzbeam run NAME --iso` attaches the bundle's cached ISO; `vzbeam run NAME --iso PATH` attaches one-shot media without changing the cache or manifest.
- Any recovery ISO implies GUI mode and conflicts with `--headless`.
- OpenBSD uses generic EFI, a persistent `nvram.bin`, a generic machine identifier, VirtIO disk/network/graphics/entropy, and read-only USB ISO media.
- Manifest schema version is 2; schema 1 or an absent schema remains readable as implicit macOS and upgrades only on a later write.
- Unknown guest values and schema versions newer than 2 fail explicitly; unknown manifest keys survive reads and writes.
- ISO bytes live at `$VZBEAM_HOME/cache/iso/<sha256>.iso`; bundles store references and never own duplicate ISO bytes.
- Existing macOS command forms and schema-1 bundles remain behaviorally compatible.
- The two-VM preflight limit applies only to a macOS launch and counts only running macOS bundles.
- OpenBSD directory sharing is rejected before sidecar spawn; no Linux behavior or plugin discovery is introduced.
- Keep the generic EFI builder guest-neutral so a future `linux` policy can reuse it without moving OpenBSD code; do not add `linux` to the accepted manifest or CLI values in this change.
- Do not add unattended installation, HTTPS ISO acquisition, ISO signature verification, a cache index/garbage collector, live media ejection, audio, ballooning, or serial-console UX.
- JSON-lines stdout remains machine-only; protocol errors and non-zero exits dominate terminal success events.
- A live PID/start-time owner protects every `<name>.pending`; stale cleanup happens only under the host lock after liveness fails, and names ending in `.pending` are invalid.
- Manifest-reading commands distinguish malformed, future-schema, and unsupported-guest bundles in their user-facing output; `ls` keeps such bundles visible.
- Default tests never boot a VM. Physical Apple Silicon validation is a separate final gate because the development host is virtualized.
- Use test-driven development for every behavior change and make one focused commit per task.

## Review Focus

1. Ambiguous or repeated `run --iso` input must return exit 2 without spawning or mutating a manifest; Task 7 lexically binds the optional value and pins bare, valued, reordered, repeated, negated, and missing-name forms.
2. A source ISO that changes during acquisition or a corrupt digest-named cache hit must never be accepted; Task 2 re-hashes promoted bytes and tests cleanup/replacement.
3. Legacy, future-schema, unknown-guest, and malformed manifests must be distinguished instead of all looking like a missing bundle; Task 1 tests each class.
4. Installer cancellation, startup failure, guest power-off, and an error after a success-looking event must have one authoritative terminal and correct `.pending` cleanup; Tasks 5 and 6 test this precedence plus active-owner refusal and confirmed-dead reclamation.
5. Cached-media loss, one-shot path failure, OpenBSD sharing, headless recovery, and macOS capacity checks must all fail before detached spawn; Task 7 asserts the spawn function is not called.

---

## File structure

**New engine files:**

- `lib/vzbeam/guest_policy.ex` — closed mapping from normalized guest OS to SSH, shutdown, sharing, re-identification, disk guidance, display label, and capacity policy.
- `lib/vzbeam/iso_cache.ex` — local ISO validation, SHA-256 retention, official-name version inference, cached-media verification, and one-shot validation.
- `lib/vzbeam/pending_bundle.ex` — PID/start-time ownership and host-lock-serialized reclamation for incomplete bundles.
- `lib/vzbeam/resolution.ex` — one anchored parser shared by `new` and `run`.
- `lib/vzbeam/run_options.ex` — command-specific parser for the optional-value `run --iso` grammar.
- `test/guest_policy_test.exs`, `test/iso_cache_test.exs`, `test/pending_bundle_test.exs`, `test/resolution_test.exs`, `test/run_options_test.exs` — focused unit coverage for those modules.

**New Swift files:**

- `swift/Sources/VzCore/GuestOS.swift` — protocol guest discriminator.
- `swift/Sources/VzCore/MacVMConfig.swift` — existing Mac platform builder moved without behavior changes.
- `swift/Sources/VzCore/EFIVMConfig.swift` — generic EFI/OpenBSD configuration builder.
- `swift/Sources/VzCore/Install.swift` — interactive OpenBSD install session and its terminal events.

**New documentation:**

- `docs/openbsd.md` — install, SSH/doas setup, normal boot, recovery, disk growth, and limitations.

**Modified engine files:**

- `lib/vzbeam/manifest.ex`, `lib/vzbeam/sidecar.ex`, `lib/vzbeam/commands/{new,run,stop,ssh,set,ls,ip}.ex`, `lib/vzbeam/ssh_conn.ex`, `lib/vzbeam/cli.ex`, `mix.exs`.
- `test/support/fake_vz` and the corresponding manifest, sidecar, command, CLI, SSH, set, and list tests.

**Modified Swift files:**

- `swift/Sources/VzCore/{Entry,Version,ReID,VMConfig,Run}.swift` and `swift/Sources/vzcheck/main.swift`.

---

### Task 1: Schema 2 normalization and closed guest policy

**Files:**

- Create: `lib/vzbeam/guest_policy.ex`
- Create: `test/guest_policy_test.exs`
- Modify: `lib/vzbeam/manifest.ex`
- Modify: `lib/vzbeam/commands/new.ex` (`restore_manifest/5`)
- Modify: `test/manifest_test.exs`
- Modify: `test/commands/new_test.exs`

**Interfaces:**

- Produces: `Manifest.normalize/1 :: {:ok, map} | {:error, term}` and schema-2 `Manifest.write_to/2`.
- Produces: `Manifest.describe_error/1` for the three manifest validation failures that commands must render explicitly.
- Produces: `GuestPolicy.guest/1`, `sidecar_guest/1`, `ssh_user/1`, `supports_share?/1`, `consumes_macos_slot?/1`, `shutdown_argv/1`, `disk_growth_note/1`, and `os_label/2` over a normalized manifest.
- Preserves: every unknown manifest key during normalization and a read-modify-write cycle.

- [ ] **Step 1: Write failing schema-normalization tests**

Add cases to `test/manifest_test.exs` that pin legacy compatibility and explicit rejection:

```elixir
test "schema 1 and absent schema normalize to macOS without dropping keys" do
  assert {:ok, %{"guestOS" => "macos", "future" => 7}} =
           VzBeam.Manifest.normalize(%{"schemaVersion" => 1, "future" => 7})

  assert {:ok, %{"guestOS" => "macos", "name" => "old"}} =
           VzBeam.Manifest.normalize(%{"name" => "old"})
end

test "legacy read is non-mutating and the next write upgrades while preserving keys" do
  path = VzBeam.Manifest.path("base")
  legacy = %{"schemaVersion" => 1, "name" => "base", "future" => %{"x" => 1}}
  File.write!(path, Jason.encode!(legacy))
  assert {:ok, %{"guestOS" => "macos"}} = VzBeam.Manifest.read("base")
  assert Jason.decode!(File.read!(path)) == legacy

  :ok = VzBeam.Manifest.write_to(path, Map.put(legacy, "cpuCount", 8))
  upgraded = Jason.decode!(File.read!(path))
  assert upgraded["schemaVersion"] == 2
  assert upgraded["guestOS"] == "macos"
  assert upgraded["future"] == %{"x" => 1}
end

test "schema 2 validates guestOS and future schemas fail explicitly" do
  assert {:ok, %{"guestOS" => "openbsd"}} =
           VzBeam.Manifest.normalize(%{"schemaVersion" => 2, "guestOS" => "openbsd"})
  assert {:error, :invalid_manifest} =
           VzBeam.Manifest.normalize(%{"schemaVersion" => 2})
  assert {:error, {:unsupported_guest, "plan9"}} =
           VzBeam.Manifest.normalize(%{"schemaVersion" => 2, "guestOS" => "plan9"})
  assert {:error, {:unsupported_schema, 3}} =
           VzBeam.Manifest.normalize(%{"schemaVersion" => 3, "guestOS" => "macos"})
  assert {:error, :invalid_manifest} = VzBeam.Manifest.normalize([])
end

test "read_or maps only an absent file to the caller's missing error" do
  assert {:error, :no_such_bundle} = VzBeam.Manifest.read_or("ghost", :no_such_bundle)
  File.write!(VzBeam.Manifest.path("base"), "not-json")
  assert {:error, :invalid_manifest} = VzBeam.Manifest.read_or("base", :no_such_bundle)
end

test "manifest failures have stable operator-facing descriptions" do
  assert VzBeam.Manifest.describe_error(:invalid_manifest) == "invalid config.json"
  assert VzBeam.Manifest.describe_error({:unsupported_schema, 3}) ==
           "unsupported schema version 3 (supports up to 2)"
  assert VzBeam.Manifest.describe_error({:unsupported_guest, "plan9"}) ==
           "unsupported guest OS plan9"
end
```

- [ ] **Step 2: Run the manifest tests and confirm the red state**

Run: `mix test test/manifest_test.exs`

Expected: FAIL because `normalize/1` does not exist and writes still stamp schema 1.

- [ ] **Step 3: Implement schema normalization and schema-2 writes**

Replace the read/write core in `lib/vzbeam/manifest.ex` with this contract:

```elixir
@schema_version 2
@guests ~w(macos openbsd)

def normalize(%{} = map) do
  version = Map.get(map, "schemaVersion", 1)
  guest = Map.get(map, "guestOS", if(version == 1, do: "macos"))

  cond do
    not is_integer(version) -> {:error, :invalid_manifest}
    version > @schema_version -> {:error, {:unsupported_schema, version}}
    version < 1 -> {:error, :invalid_manifest}
    not is_binary(guest) -> {:error, :invalid_manifest}
    guest not in @guests -> {:error, {:unsupported_guest, guest}}
    true -> {:ok, Map.put(map, "guestOS", guest)}
  end
end

def normalize(_), do: {:error, :invalid_manifest}

def read(name) do
  with {:ok, body} <- File.read(path(name)),
       {:ok, map} <- Jason.decode(body),
       {:ok, normalized} <- normalize(map) do
    {:ok, normalized}
  else
    {:error, %Jason.DecodeError{}} -> {:error, :invalid_manifest}
    error -> error
  end
end

def read_or(name, missing_error) do
  case read(name) do
    {:error, :enoent} -> {:error, missing_error}
    result -> result
  end
end

def write_to(path, map) do
  with {:ok, normalized} <- normalize(map) do
    stamped = Map.put(normalized, "schemaVersion", @schema_version)
    AtomicFile.write(path, Jason.encode!(stamped, pretty: true))
  end
end

def describe_error(:invalid_manifest), do: "invalid config.json"
def describe_error({:unsupported_schema, version}),
  do: "unsupported schema version #{version} (supports up to #{@schema_version})"
def describe_error({:unsupported_guest, guest}), do: "unsupported guest OS #{guest}"
```

- [ ] **Step 4: Write failing guest-policy tests**

Create `test/guest_policy_test.exs`:

```elixir
defmodule VzBeam.GuestPolicyTest do
  use ExUnit.Case, async: true
  alias VzBeam.GuestPolicy

  test "macOS policy preserves existing behavior" do
    m = %{"guestOS" => "macos"}
    assert GuestPolicy.guest(m) == :macos
    assert GuestPolicy.sidecar_guest(m) == "macos"
    assert GuestPolicy.ssh_user(m) == "admin"
    assert GuestPolicy.supports_share?(m)
    assert GuestPolicy.consumes_macos_slot?(m)
    assert GuestPolicy.shutdown_argv(m) == ["sudo", "-n", "shutdown", "-h", "now"]
  end

  test "OpenBSD policy selects generic behavior and stored SSH user" do
    m = %{"guestOS" => "openbsd", "sshUser" => "deploy"}
    assert GuestPolicy.guest(m) == :openbsd
    assert GuestPolicy.sidecar_guest(m) == "openbsd"
    assert GuestPolicy.ssh_user(m) == "deploy"
    refute GuestPolicy.supports_share?(m)
    refute GuestPolicy.consumes_macos_slot?(m)
    assert GuestPolicy.shutdown_argv(m) == ["doas", "-n", "/sbin/shutdown", "-p", "now"]
    assert GuestPolicy.os_label(m, %{"version" => "7.9"}) == "OpenBSD 7.9"
  end
end
```

- [ ] **Step 5: Implement the closed policy mapping**

Create `lib/vzbeam/guest_policy.ex` with explicit clauses, not a plugin registry:

```elixir
defmodule VzBeam.GuestPolicy do
  @moduledoc "Closed guest behavior mapping for normalized manifests."
  alias VzBeam.Defaults

  def guest(%{"guestOS" => "macos"}), do: :macos
  def guest(%{"guestOS" => "openbsd"}), do: :openbsd
  def sidecar_guest(manifest), do: manifest |> guest() |> Atom.to_string()
  def ssh_user(manifest), do: manifest["sshUser"] || Defaults.values().ssh_user

  def supports_share?(manifest), do: guest(manifest) == :macos
  def consumes_macos_slot?(manifest), do: guest(manifest) == :macos

  def shutdown_argv(%{"guestOS" => "macos"}),
    do: ["sudo", "-n", "shutdown", "-h", "now"]
  def shutdown_argv(%{"guestOS" => "openbsd"}),
    do: ["doas", "-n", "/sbin/shutdown", "-p", "now"]

  def disk_growth_note(%{"guestOS" => "macos"}), do: :macos_recovery_partition
  def disk_growth_note(%{"guestOS" => "openbsd"}), do: :openbsd_unallocated_space

  def os_label(%{"guestOS" => "macos"}, %{"version" => v, "build" => b}), do: "#{v} (#{b})"
  def os_label(%{"guestOS" => "macos"}, _), do: "-"
  def os_label(%{"guestOS" => "openbsd"}, %{"version" => v}), do: "OpenBSD #{v}"
  def os_label(%{"guestOS" => "openbsd"}, _), do: "OpenBSD"
end
```

- [ ] **Step 6: Stamp new macOS manifests with an explicit guest**

Extend `restore_manifest/5` in `lib/vzbeam/commands/new.ex`:

```elixir
%{"schemaVersion" => 2, "guestOS" => "macos", "name" => name, "base" => nil,
  "image" => %{"version" => entry["version"], "build" => entry["build"], "source" => entry["source"]},
  "machineIdentifier" => r.machine_identifier, "hardwareModel" => r.hardware_model,
  "macAddress" => r.mac_address,
  "cpuCount" => cpu, "memoryBytes" => mem_bytes, "createdAt" => now()}
```

Update exact-map assertions in `test/manifest_test.exs` and `test/commands/new_test.exs` to expect schema 2 and `guestOS: macos`. Do not persist `sshUser` in new macOS manifests; `GuestPolicy.ssh_user/1` preserves the existing default for a missing field, while OpenBSD stores the installer-selected user.

- [ ] **Step 7: Run focused and full verification**

Run: `mix test test/manifest_test.exs test/guest_policy_test.exs test/commands/new_test.exs`

Expected: PASS with 0 failures.

Run: `mix test`

Expected: PASS with 0 failures.

- [ ] **Step 8: Commit**

```bash
git add lib/vzbeam/manifest.ex lib/vzbeam/guest_policy.ex lib/vzbeam/commands/new.ex test/manifest_test.exs test/guest_policy_test.exs test/commands/new_test.exs
git commit -m "feat: add guest-aware manifest schema"
```

---

### Task 2: Content-addressed local ISO retention

**Files:**

- Create: `lib/vzbeam/iso_cache.ex`
- Create: `test/iso_cache_test.exs`
- Modify: `mix.exs` (`extra_applications`)

**Interfaces:**

- Produces: `IsoCache.ensure/1 :: {:ok, :fetched | :cached, map} | {:error, term}`.
- Produces: `IsoCache.resolve_cached/1 :: {:ok, Path.t()} | {:error, {:missing_cached_iso | :corrupt_cached_iso, String.t()}}`.
- Produces: `IsoCache.validate_one_shot/1 :: {:ok, Path.t()} | {:error, term}` and `IsoCache.infer_version/1`.
- Entry shape: `%{"kind" => "iso", "source" => absolute_source, "file" => "<sha256>.iso", "sha256" => digest}` with optional `"version"`.

- [ ] **Step 1: Write failing cache tests for identity, deduplication, and names**

Create `test/iso_cache_test.exs` with an isolated `VZBEAM_HOME` and these core cases:

```elixir
test "ensure hashes, stores, and deduplicates local ISO bytes", %{home: home} do
  source = Path.join(home, "install79.iso")
  File.write!(source, "openbsd-media")

  assert {:ok, :fetched, entry} = IsoCache.ensure(source)
  assert entry["kind"] == "iso"
  assert entry["source"] == Path.expand(source)
  assert entry["version"] == "7.9"
  assert entry["file"] == entry["sha256"] <> ".iso"
  assert File.read!(Path.join(IsoCache.dir(), entry["file"])) == "openbsd-media"
  assert {:ok, :cached, ^entry} = IsoCache.ensure(source)
end

test "official basenames infer versions and arbitrary names do not" do
  assert IsoCache.infer_version("install79.iso") == "7.9"
  assert IsoCache.infer_version("cd79.iso") == "7.9"
  assert IsoCache.infer_version("recovery.iso") == nil
end
```

- [ ] **Step 2: Add failing validation and corruption tests**

Add tests for a directory, missing path, empty file, an `https://` string, a copy failure that leaves no pending file, a source mutation between initial hash and copied-byte hash, a corrupt existing digest-named file, `resolve_cached/1` missing/corrupt errors, and a valid one-shot path. Inject `hash` and `copy` functions into `ensure/2` so each race is deterministic.

The mutation assertion must use this shape:

```elixir
deps = %{
  hash: &IsoCache.sha256/1,
  copy: fn src, dst ->
    :ok = File.write(src, "changed-after-first-hash")
    File.cp(src, dst)
  end
}

assert {:error, :source_changed} = IsoCache.ensure(source, deps)
assert Path.wildcard(Path.join(IsoCache.dir(), "*.pending")) == []
```

Pin validation and cached-byte verification with these assertions:

```elixir
assert {:error, :not_local_file} = IsoCache.ensure("https://cdn.example/install79.iso")
assert {:error, :not_regular} = IsoCache.ensure(Path.join(home, "missing.iso"))

empty = Path.join(home, "empty.iso")
File.touch!(empty)
assert {:error, :empty_iso} = IsoCache.ensure(empty)

assert {:ok, :fetched, entry} = IsoCache.ensure(source)
cached = Path.join(IsoCache.dir(), entry["file"])
digest = entry["sha256"]
File.write!(cached, "corrupt")
assert {:error, {:corrupt_cached_iso, ^digest}} =
         IsoCache.resolve_cached(%{"image" => entry})

File.rm!(cached)
assert {:error, {:missing_cached_iso, ^digest}} =
         IsoCache.resolve_cached(%{"image" => entry})
expected_source = Path.expand(source)
assert {:ok, ^expected_source} = IsoCache.validate_one_shot(source)
```

Create an unrelated orphan `*.pending` file before a successful `ensure/1` and assert it remains untouched and is never selected. Crash-orphaned cache temporaries are deliberately left for the deferred cache-GC feature; only the unique temporary created by the current `ensure/2` call is removed on its controlled error path.

- [ ] **Step 3: Run the cache test and confirm the red state**

Run: `mix test test/iso_cache_test.exs`

Expected: FAIL because `VzBeam.IsoCache` does not exist.

- [ ] **Step 4: Implement streaming SHA-256 and official-name inference**

Create `lib/vzbeam/iso_cache.ex` with these public helpers and a 1 MiB streaming hash:

```elixir
defmodule VzBeam.IsoCache do
  alias VzBeam.Home
  @chunk 1_048_576

  def dir, do: Path.join([Home.root(), "cache", "iso"])

  def sha256(path) do
    try do
      digest =
        path
        |> File.stream!(@chunk)
        |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)
      {:ok, digest}
    rescue
      e in File.Error -> {:error, e.reason}
    end
  end

  def infer_version(path) do
    case Regex.run(~r/^(?:install|cd)(\d)(\d)\.iso$/i, Path.basename(path)) do
      [_, major, minor] -> major <> "." <> minor
      _ -> nil
    end
  end
end
```

- [ ] **Step 5: Implement atomic verified placement**

Implement `ensure/2` in this order: reject URI schemes and non-regular/empty files; hash the source; return `:cached` only when the final file hashes to its filename digest; copy to a unique `.pending` file with `cp -c`; re-hash pending bytes; reject `:source_changed` when the digest differs; atomically rename; always remove the task's pending file in the error path.

Use these private/default boundaries:

```elixir
def ensure(source, deps \\ %{hash: &sha256/1, copy: &copy_clone/2})
def validate_one_shot(source)
def resolve_cached(%{"image" => %{"sha256" => digest, "file" => file}})

defp copy_clone(src, dst) do
  case System.cmd("cp", ["-c", src, dst], stderr_to_stdout: true) do
    {_, 0} -> :ok
    {_clone_out, _} ->
      File.rm(dst)
      case System.cmd("cp", [src, dst], stderr_to_stdout: true) do
        {_, 0} -> :ok
        {out, _} -> {:error, {:copy_failed, String.trim(out)}}
      end
  end
end
```

The clone-first/plain-copy fallback is required because a user-selected ISO can live on a volume that does not support `clonefile(2)`. Build the entry by starting with the required five fields and conditionally adding `version`; never create an index file or delete an ISO on bundle removal.

- [ ] **Step 6: Make crypto an explicit runtime application**

Add `:crypto` to the existing `extra_applications` list in `mix.exs`; preserve every other `application/0` key:

```elixir
def application, do: [mod: {VzBeam.Application, []}, extra_applications: [:logger, :crypto]]
```

- [ ] **Step 7: Verify the cache and regression suite**

Run: `mix test test/iso_cache_test.exs`

Expected: PASS with 0 failures.

Run: `mix test`

Expected: PASS with 0 failures.

- [ ] **Step 8: Commit**

```bash
git add lib/vzbeam/iso_cache.ex test/iso_cache_test.exs mix.exs
git commit -m "feat: retain local ISOs by content digest"
```

---

### Task 3: Protocol 2 and guest-aware identity

**Files:**

- Create: `swift/Sources/VzCore/GuestOS.swift`
- Modify: `swift/Sources/VzCore/{Entry,Version,ReID}.swift`
- Modify: `swift/Sources/vzcheck/main.swift`
- Modify: `lib/vzbeam/sidecar.ex`
- Modify: `lib/vzbeam/commands/new.ex` (clone re-identification call)
- Modify: `test/support/fake_vz`
- Modify: `test/sidecar_test.exs`
- Modify: `test/commands/new_test.exs`

**Interfaces:**

- Produces: Swift `GuestOS` values `.macos` and `.openbsd`.
- Produces: `Sidecar.reid/2` invoked as `reid(:macos | :openbsd, runner)` and sidecar argv `reid --guest <macos|openbsd>`.
- Changes: both version emitters and the fake sidecar to protocol 2.

- [ ] **Step 1: Write failing Elixir protocol and re-identification tests**

Update `test/sidecar_test.exs` to expect protocol 2 and guest argv:

```elixir
test "check_version accepts protocol 2" do
  {:ok, path} = Sidecar.locate()
  assert :ok = Sidecar.check_version(path)
end

test "reid passes the guest and parses the identity" do
  parent = self()
  runner = fn _path, ["reid", "--guest", "openbsd"], _opts ->
    send(parent, :openbsd_reid)
    {~s({"type":"reid","machineIdentifier":"GENERIC","macAddress":"5e:11:22:33:44:55"}\n), 0}
  end

  assert {:ok, %{machine_identifier: "GENERIC"}} = Sidecar.reid(:openbsd, runner)
  assert_received :openbsd_reid
end
```

Change the clone test dependency to `reid: fn guest -> ... end` and assert cloning a normalized macOS fixture passes `:macos`.

- [ ] **Step 2: Run focused tests and confirm the red state**

Run: `mix test test/sidecar_test.exs test/commands/new_test.exs`

Expected: FAIL because protocol 1 and the zero-argument `reid` contract still exist.

- [ ] **Step 3: Bump protocol and make re-identification guest-aware**

Change `@protocol_version` in `lib/vzbeam/sidecar.ex`, `runVersion()` in Swift, and `test/support/fake_vz` to 2. Change the Elixir API to:

```elixir
def reid(guest, runner \\ &System.cmd/3) when guest in [:macos, :openbsd] do
  with {:ok, events} <- call("reid", ["--guest", Atom.to_string(guest)], runner),
       {:event, "reid", m} <- find(events, "reid") do
    {:ok, %{machine_identifier: m["machineIdentifier"], mac_address: m["macAddress"]}}
  end
end
```

Update clone orchestration to compute `guest = GuestPolicy.guest(base_m)` and call `deps.reid.(guest)`.

- [ ] **Step 4: Add the Swift guest discriminator and generic identity**

Create `GuestOS.swift`:

```swift
import Foundation

public enum GuestOS: String {
    case macos
    case openbsd

    public static func parse(_ value: String?) throws -> GuestOS {
        guard let value, let guest = GuestOS(rawValue: value) else {
            throw ConfigError.badField("guest")
        }
        return guest
    }
}
```

Change `runReid` to parse `--guest`. `mintIdentity(for:)` must use `VZMacMachineIdentifier` for macOS and `VZGenericMachineIdentifier` for OpenBSD, with `VZMACAddress.randomLocallyAdministered()` for both. Update `Entry.swift` to pass `rest` into `runReid(rest)`.

- [ ] **Step 5: Add guest identity checks to `vzcheck`**

```swift
check("guest.macos", (try? GuestOS.parse("macos")) == .macos)
check("guest.openbsd", (try? GuestOS.parse("openbsd")) == .openbsd)
check("guest.unknown", (try? GuestOS.parse("linux")) == nil)

let (genericID, genericMAC) = mintIdentity(for: .openbsd)
check("reid.generic.base64", Data(base64Encoded: genericID) != nil)
check("reid.generic.mac", genericMAC.contains(":"))
```

- [ ] **Step 6: Verify protocol and identity changes**

Run: `swift run --package-path swift vzcheck`

Expected: `ALL CHECKS PASS` and exit 0.

Run: `mix test test/sidecar_test.exs test/commands/new_test.exs`

Expected: PASS with 0 failures.

Run: `mix test`

Expected: PASS with 0 failures.

- [ ] **Step 7: Commit**

```bash
git add swift/Sources/VzCore/GuestOS.swift swift/Sources/VzCore/Entry.swift swift/Sources/VzCore/Version.swift swift/Sources/VzCore/ReID.swift swift/Sources/vzcheck/main.swift lib/vzbeam/sidecar.ex lib/vzbeam/commands/new.ex test/support/fake_vz test/sidecar_test.exs test/commands/new_test.exs
git commit -m "feat: add protocol 2 guest identity"
```

---

### Task 4: Generic EFI configuration and guest-aware sidecar run

**Files:**

- Create: `swift/Sources/VzCore/MacVMConfig.swift`
- Create: `swift/Sources/VzCore/EFIVMConfig.swift`
- Modify: `swift/Sources/VzCore/{VMConfig,Run}.swift`
- Modify: `swift/Sources/vzcheck/main.swift`
- Modify: `lib/vzbeam/commands/run.ex`
- Modify: `test/commands/run_test.exs`

**Interfaces:**

- Consumes: Task 3 `GuestOS` and protocol-2 sidecar.
- Produces: `RunOpts(guest:machineId:hardwareModel:mac:disk:aux:nvram:iso:cpu:mem:gui:width:height:share:createNVRAM:)`.
- Produces: `buildConfiguration(_:)` routing to `buildMacConfiguration(_:)` or `buildEFIConfiguration(_:)`.
- Preserves: current macOS run behavior while accepting generic EFI configuration for later install/run tasks.

The shared options type is explicit so both builders and `vzcheck` use the same labels:

```swift
public struct RunOpts {
    public let guest: GuestOS
    public let machineId: String
    public let hardwareModel: String?
    public let mac: String
    public let disk: String
    public let aux: String?
    public let nvram: String?
    public let iso: String?
    public let cpu: Int
    public let mem: UInt64
    public let gui: Bool
    public let width: Int
    public let height: Int
    public let share: (tag: String, path: String)?
    public let createNVRAM: Bool

    public init(guest: GuestOS, machineId: String, hardwareModel: String?,
                mac: String, disk: String, aux: String?, nvram: String?,
                iso: String?, cpu: Int, mem: UInt64, gui: Bool,
                width: Int, height: Int, share: (String, String)?,
                createNVRAM: Bool) {
        self.guest = guest; self.machineId = machineId
        self.hardwareModel = hardwareModel; self.mac = mac; self.disk = disk
        self.aux = aux; self.nvram = nvram; self.iso = iso
        self.cpu = cpu; self.mem = mem; self.gui = gui
        self.width = width; self.height = height
        self.share = share.map { (tag: $0.0, path: $0.1) }
        self.createNVRAM = createNVRAM
    }
}

public func buildConfiguration(_ opts: RunOpts) throws -> VZVirtualMachineConfiguration {
    switch opts.guest {
    case .macos: return try buildMacConfiguration(opts)
    case .openbsd: return try buildEFIConfiguration(opts)
    }
}
```

- [ ] **Step 1: Split the Mac builder without behavior changes**

Keep `RunOpts`, `ConfigError`, and the router in `VMConfig.swift`. Move the current Mac-specific body into `MacVMConfig.swift` as:

```swift
func buildMacConfiguration(_ o: RunOpts) throws -> VZVirtualMachineConfiguration
```

Require `hardwareModel` and `aux` only inside that function. Preserve Mac graphics, VirtioFS, disk, NAT, inputs, and validation byte-for-byte.

- [ ] **Step 2: Implement the generic EFI builder**

Create `EFIVMConfig.swift` with `buildEFIConfiguration(_:)`. Its essential construction is:

```swift
let platform = VZGenericPlatformConfiguration()
platform.machineIdentifier = genericID

let boot = VZEFIBootLoader()
let variableStore: VZEFIVariableStore
if o.createNVRAM {
    variableStore = try VZEFIVariableStore(
        creatingVariableStoreAt: nvramURL, options: [])
} else {
    guard FileManager.default.fileExists(atPath: nvramURL.path) else {
        throw ConfigError.badField("nvram")
    }
    variableStore = VZEFIVariableStore(url: nvramURL)
}
boot.variableStore = variableStore

let isoAttachment = try o.iso.map {
    try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: $0), readOnly: true)
}
let diskAttachment = try VZDiskImageStorageDeviceAttachment(
    url: URL(fileURLWithPath: o.disk), readOnly: false)

var storage: [VZStorageDeviceConfiguration] = []
if let isoAttachment {
    storage.append(VZUSBMassStorageDeviceConfiguration(attachment: isoAttachment))
}
storage.append(VZVirtioBlockDeviceConfiguration(attachment: diskAttachment))
cfg.storageDevices = storage

let graphics = VZVirtioGraphicsDeviceConfiguration()
graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(
    widthInPixels: o.width, heightInPixels: o.height)]
cfg.graphicsDevices = [graphics]
cfg.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
```

Also set CPU/RAM, NAT VirtIO network with the persisted MAC, and GUI-only USB keyboard/digitizer. Reject `share != nil`, a missing/invalid generic identity, missing `nvram`, and a missing existing NVRAM file when `createNVRAM` is false. Call `cfg.validate()` before returning.

- [ ] **Step 3: Make `run` parse guest-specific fields**

Update Swift `runRun` to require `--guest`, always require machine ID/MAC/disk/CPU/memory, and conditionally require Mac `--hardware-model`/`--aux` or OpenBSD `--nvram`. Accept optional `--iso` for OpenBSD. Construct the expanded `RunOpts` and keep `RunSession` startup, signal, GUI, and terminal behavior unchanged:

```swift
let guest = try GuestOS.parse(a.value("guest"))
let opts = RunOpts(guest: guest, machineId: mid,
                   hardwareModel: a.value("hardware-model"), mac: mac,
                   disk: disk, aux: a.value("aux"), nvram: a.value("nvram"),
                   iso: a.value("iso"), cpu: cpu, mem: mem,
                   gui: a.has("gui"), width: w, height: h,
                   share: share, createNVRAM: false)
```

Reject `--iso` and `--nvram` for `.macos`; reject `--hardware-model`, `--aux`, and `--share` for `.openbsd`. Add pure parser/configuration checks for these cross-guest combinations so a malformed argv cannot silently carry ignored hardware fields.

Update the existing Elixir macOS argv builder immediately to include `--guest macos`, and extend its argv regression test. This keeps a Task-4 sidecar usable with existing macOS bundles before OpenBSD run orchestration lands.

- [ ] **Step 4: Add non-booting Swift configuration checks**

Create temporary non-empty disk/ISO files and a temporary NVRAM path, build a GUI OpenBSD configuration with `createNVRAM: true`, and check the runtime types/order of platform, boot loader, storage, graphics, entropy, keyboard, and pointing-device arrays. Build a second headless configuration from the created NVRAM and assert graphics remain while inputs are absent. Continue using `swift run vzcheck`, not XCTest.

- [ ] **Step 5: Run Swift and Elixir verification**

Run: `swift run --package-path swift vzcheck`

Expected: `ALL CHECKS PASS` and exit 0.

Run: `mix test test/commands/run_test.exs`

Expected: PASS with 0 failures.

Run: `mix test`

Expected: PASS with 0 failures.

- [ ] **Step 6: Commit**

```bash
git add swift/Sources/VzCore/VMConfig.swift swift/Sources/VzCore/MacVMConfig.swift swift/Sources/VzCore/EFIVMConfig.swift swift/Sources/VzCore/Run.swift swift/Sources/vzcheck/main.swift lib/vzbeam/commands/run.ex test/commands/run_test.exs
git commit -m "feat: add generic EFI guest configuration"
```

---

### Task 5: Interactive sidecar install command

**Files:**

- Create: `swift/Sources/VzCore/Install.swift`
- Modify: `swift/Sources/VzCore/Entry.swift`
- Modify: `swift/Sources/vzcheck/main.swift`
- Modify: `lib/vzbeam/sidecar.ex`
- Modify: `test/support/fake_vz`
- Modify: `test/sidecar_test.exs`

**Interfaces:**

- Consumes: Task 4 `GuestOS.openbsd`, `RunOpts`, and `buildConfiguration(_:)` with `createNVRAM: true`.
- Produces: `Sidecar.install/2` with options `%{iso:, disk:, nvram:, cpu:, mem:, resolution:}` and an internal `--parent-pid` watchdog argument.
- Produces events: `install_started` followed by exactly one terminal `installed` or `error`.
- `installed` data: `%{machine_identifier: String.t(), mac_address: String.t()}`.

- [ ] **Step 1: Write failing install transport tests**

Add to `test/sidecar_test.exs`:

```elixir
@install %{iso: "i", disk: "d", nvram: "n", cpu: 2, mem: 2_147_483_648,
           resolution: "1920x1200"}

test "install streams startup and returns the installed identity" do
  parent = self()
  assert {:ok, %{machine_identifier: "OID", mac_address: "5e:aa:bb:cc:dd:ee"}} =
           Sidecar.install(@install, fn event -> send(parent, event) end)
  assert_received {:event, "install_started", %{"pid" => pid}} when is_integer(pid)
end

test "install error dominates a prior success-looking event" do
  # Reuse the helper already defined near the top of sidecar_test.exs.
  fake_vz_emitting("""
  echo '{"type":"installed","machineIdentifier":"bad","macAddress":"bad"}'
  echo '{"type":"error","domain":"vz","code":130,"message":"install cancelled"}'
  exit 1
  """)
  assert {:error, {:vz, "vz", 130, "install cancelled"}} = Sidecar.install(@install)
end
```

- [ ] **Step 2: Confirm the red state**

Run: `mix test test/sidecar_test.exs`

Expected: FAIL because `install` is not a known terminal and `Sidecar.install/2` does not exist.

- [ ] **Step 3: Add the Elixir install transport and fake events**

Add `"install" => ["installed"]` to `@terminals`, then implement:

```elixir
def install(opts, on_event \\ fn _ -> :ok end) do
  args = ["--guest", "openbsd", "--iso", opts.iso, "--disk", opts.disk,
          "--nvram", opts.nvram, "--cpu", to_string(opts.cpu),
          "--mem", to_string(opts.mem), "--resolution", opts.resolution,
          "--parent-pid", System.pid()]

  with {:ok, events} <- stream("install", args, on_event),
       {:event, "installed", m} <- find(events, "installed") do
    {:ok, %{machine_identifier: m["machineIdentifier"], mac_address: m["macAddress"]}}
  end
end
```

Extend `test/support/fake_vz` so `install` emits `{"type":"install_started","pid":$$}` (an unquoted JSON integer from the shell PID) and then exactly `{"type":"installed","machineIdentifier":"OID","macAddress":"5e:aa:bb:cc:dd:ee"}`. Those values satisfy the first transport test above. Its version event was already changed to protocol 2 in Task 3; do not add a second protocol bump here. `fake_vz_emitting/1` already exists in `test/sidecar_test.exs`; reuse it rather than adding new scaffolding.

- [ ] **Step 4: Implement `InstallSession` lifecycle**

Create `Install.swift` with the same file-scope strong-holder pattern already used by `liveRun` in `Run.swift`; the package currently compiles in Swift 5 language mode even when driven by a Swift 6 compiler. Parse and validate `--guest openbsd`, ISO, disk, NVRAM, CPU, memory, resolution, and a positive `--parent-pid`. After parsing, mint a generic identity and MAC, construct `RunOpts` with GUI true and ISO attached, then start a main-queue VM. If the package is later moved to Swift 6 language mode, isolate both the holder and `runInstall`/`InstallSession` to `@MainActor` together rather than marking only the mutable global.

The session state machine must be explicit:

```swift
private enum InstallState { case starting, running, finishing, finished }

public struct InstallOpts {
    public let guest: GuestOS
    public let iso: String
    public let disk: String
    public let nvram: String
    public let cpu: Int
    public let mem: UInt64
    public let width: Int
    public let height: Int
    public let parentPID: pid_t
}
```

`InstallOpts` intentionally contains only parsed input. `runInstall` calls `mintIdentity(for: .openbsd)` and uses the result plus these fields to build the non-optional `machineId` and `mac` members required by `RunOpts`; the pure parser never mints identity.

- Successful `vm.start` changes `.starting` to `.running` and emits `install_started` with `getpid()`.
- `guestDidStop` while `.running` emits `installed` with the minted identity/MAC and exits 0. In `.starting`, `.finishing`, or `.finished`, it must not emit success; `.starting` becomes a structured installation failure and the finishing/finished paths remain governed by `finishOnce`.
- `didStopWithError`, config failure, or start failure emits one structured error and exits nonzero.
- `windowShouldClose`, SIGINT, SIGTERM, or SIGHUP transitions to `.finishing`, requests `vm.stop`, and always emits `vz` code 130 `install cancelled` before exiting nonzero even if cancellation happens during `.starting` or `vm.stop` reports an error. Once state is `.finishing`, a racing `didStopWithError` or `guestDidStop` must route to the cancellation terminal rather than win `finishOnce` with another result. Start a retained five-second cancellation deadline before requesting stop; if the completion/delegate never arrives, `finishOnce` emits the same cancellation terminal and exits so the BEAM cannot hang indefinitely.
- A retained one-second `DispatchSourceTimer` checks `kill(parentPID, 0)`; `ESRCH` uses the same cancellation path so a dead BEAM cannot leave a running installer sidecar.
- Call `signal(signum, SIG_IGN)` before creating each dispatch signal source so the process-wide default action cannot win the race; cancel the retained sources from `finishOnce`.
- Retain every `DispatchSourceSignal` in an array for the lifetime of the session; otherwise ARC can silently remove signal handlers.
- The window delegate returns `false` while cancellation is in progress, preventing AppKit from silently orphaning the VM.
- `finishOnce` guards all terminal paths.

Update `Entry.swift` with `case "install": runInstall(rest)`.

- [ ] **Step 5: Add parser/event checks to `vzcheck`**

Extract a pure `parseInstallOpts(_:) throws -> InstallOpts` used by `runInstall`. In `vzcheck`, assert valid flags produce parsed `.openbsd`, ISO/disk/NVRAM, dimensions, and positive parent PID. Separately build `RunOpts` from fixed test identity/MAC plus the parsed fields and assert `iso` and `createNVRAM == true`; missing ISO, a non-OpenBSD guest, missing NVRAM, or a non-positive/non-numeric parent PID throws `ConfigError`.

- [ ] **Step 6: Verify install code without booting**

Run: `swift run --package-path swift vzcheck`

Expected: `ALL CHECKS PASS` and exit 0.

Run: `mix test test/sidecar_test.exs`

Expected: PASS with 0 failures.

Run: `mix test`

Expected: PASS with 0 failures.

- [ ] **Step 7: Commit**

```bash
git add swift/Sources/VzCore/Install.swift swift/Sources/VzCore/Entry.swift swift/Sources/vzcheck/main.swift lib/vzbeam/sidecar.ex test/support/fake_vz test/sidecar_test.exs
git commit -m "feat: add interactive OpenBSD install sidecar"
```

---

### Task 6: `new --iso` OpenBSD creation flow

**Files:**

- Create: `lib/vzbeam/pending_bundle.ex`
- Create: `lib/vzbeam/resolution.ex`
- Create: `test/pending_bundle_test.exs`
- Create: `test/resolution_test.exs`
- Modify: `lib/vzbeam/commands/new.ex`
- Modify: `test/home_test.exs`
- Modify: `test/commands/new_test.exs`

**Interfaces:**

- Consumes: `IsoCache.ensure/1`, `Sidecar.install/2`, and schema-2 manifests.
- Produces: `new NAME --iso PATH [--cpu N] [--mem-gb M] [--disk-gb G] [--ssh-user USER] [--resolution WxH]`.
- Produces bundle files: `config.json`, `disk.img`, and `nvram.bin`; ISO bytes remain in the shared cache.
- Produces: `Resolution.parse/1 :: {:ok, {pos_integer, pos_integer}} | {:error, :bad_resolution}` for both `new` and `run`.
- Produces: `PendingBundle.claim/2 :: {:ok, claim} | {:error, reason}` plus `cleanup/2` and `promote/2` returning `:ok | {:error, reason}`; every operation performs its inspection plus mutation under the existing host lock. A claim records the current BEAM OS PID/start time in `<name>.pending/install-owner.json` before that lock is released.

- [ ] **Step 1: Write failing resolution and pending-owner tests**

Create `test/resolution_test.exs` and pin an anchored, shared grammar:

```elixir
assert {:ok, {1280, 800}} = Resolution.parse("1280x800")
for value <- [nil, "", "0x800", "1280x0", "1280X800", "1280x800junk"] do
  assert {:error, :bad_resolution} = Resolution.parse(value)
end
```

Create `test/pending_bundle_test.exs` with a real temporary `VZBEAM_HOME`. Use an immediate `with_lock` dependency and injectable `process_start` function to prove:

- claiming an absent pending bundle creates `install-owner.json` before returning;
- a final bundle created after the command's early validation returns `:exists` from the locked claim and is never overwritten;
- an owner whose PID/start time still matches returns `{:error, :creation_in_progress}` without deleting any pending bytes;
- a valid dead owner is reclaimed and replaced by the caller's owner;
- a missing or malformed owner returns `:pending_owner_unreadable` without deleting its sentinel bytes;
- `cleanup/2` refuses to delete a directory whose owner record changed and performs deletion while its injected lock is held;
- `promote/2` performs final-existence recheck, rename, and owner removal while its injected lock is held;
- a lock timeout/corruption error is propagated without touching pending state.

The production boundary is explicit:

```elixir
def claim(name, deps \\ %{with_lock: &VzBeam.Lock.with_lock/1,
                          process_start: &VzBeam.Pidfile.process_start/1})
def cleanup(%PendingBundle{} = claim, with_lock \\ &VzBeam.Lock.with_lock/1)
def promote(%PendingBundle{} = claim, with_lock \\ &VzBeam.Lock.with_lock/1)
```

- [ ] **Step 2: Extend command-test dependencies for ISO installation and pending claims**

In `test/commands/new_test.exs`, add `ensure_iso`, `install`, `claim_pending`, `cleanup_pending`, and `promote_pending` dependencies. Default pending dependencies call the real `PendingBundle` module. The install stub must touch `opts.nvram`, report `install_started`, report `installed`, and return generic identity fields:

```elixir
ensure_iso: fn _ ->
  {:ok, :fetched, %{"kind" => "iso", "source" => "/tmp/install79.iso",
                     "file" => "abc.iso", "sha256" => "abc", "version" => "7.9"}}
end,
install: fn opts, report ->
  File.touch!(opts.nvram)
  report.({:event, "install_started", %{"pid" => 123}})
  report.({:event, "installed", %{}})
  {:ok, %{machine_identifier: "OPENBSD-ID", mac_address: "5e:79:00:00:00:01"}}
end
```

- [ ] **Step 3: Write failing success and manifest tests**

```elixir
test "--iso installs OpenBSD in pending and promotes a complete bundle", %{home: home} do
  assert {:ok, out} = New.run(["obsd", "--iso", "/tmp/install79.iso",
                                "--ssh-user", "deploy", "--resolution", "1280x800"], deps())
  assert IO.iodata_to_binary(out) =~ "created obsd"
  manifest = Jason.decode!(File.read!(Path.join([home, "obsd", "config.json"])))
  assert manifest["guestOS"] == "openbsd"
  assert manifest["sshUser"] == "deploy"
  assert manifest["image"]["sha256"] == "abc"
  assert manifest["machineIdentifier"] == "OPENBSD-ID"
  refute Map.has_key?(manifest, "hardwareModel")
  assert File.regular?(Path.join([home, "obsd", "disk.img"]))
  assert File.regular?(Path.join([home, "obsd", "nvram.bin"]))
  refute File.exists?(Path.join(home, "obsd.pending"))
end
```

- [ ] **Step 4: Add failing input, ownership, instructions, and cleanup tests**

Cover `--iso` versus `--image`, `--iso` versus a base, blank/invalid `--ssh-user`, shared-parser resolution failures, install cancellation, install startup error, and `installed` success. Assert instructions mention the selected user, `sshd`, and `halt -p`. For every controlled error after a successful claim, assert both the final bundle and owned `.pending` directory are absent. Assert ISO acquisition happens before `PendingBundle.claim/2` by ordering messages from injected dependencies.

Add three concurrency/name regressions:

1. Make a real claim for `obsd`, place a sentinel file in it, then call `New.run/2` for the same name. Expect `creation already in progress` and prove the sentinel remains.
2. Seed a dead owner, run `new`, and prove the stale pending bytes are replaced.
3. Reject names ending in `.pending` for clone, restore, and ISO forms. In `test/home_test.exs`, create `<name>.pending/config.json` and assert `Home.bundles/0` and `Home.exists?/1` keep it invisible.

`Home` already implements both filters, so this task adds only the regression test; modify and stage `lib/vzbeam/home.ex` only if that test disproves the existing behavior.

Use concrete assertions such as:

```elixir
for args <- [
      ["obsd", "--iso", "x.iso", "--image", "latest"],
      ["obsd", "base", "--iso", "x.iso"],
      ["obsd", "--iso", "x.iso", "--ssh-user", "root"],
      ["obsd", "--iso", "x.iso", "--ssh-user", "bad@host"],
      ["obsd", "--iso", "x.iso", "--resolution", "wide"],
      ["obsd.pending", "--iso", "x.iso"]
    ] do
  assert {:error, 2, _} = New.run(args, deps())
end

cancel = %{deps() | install: fn _opts, _report ->
  {:error, {:vz, "vz", 130, "install cancelled"}}
end}
assert {:error, 1, message} = New.run(["obsd", "--iso", "x.iso"], cancel)
assert IO.iodata_to_binary(message) =~ "cancelled"
refute File.exists?(Path.join(home, "obsd"))
refute File.exists?(Path.join(home, "obsd.pending"))
```

- [ ] **Step 5: Confirm the red state**

Run: `mix test test/resolution_test.exs test/pending_bundle_test.exs test/home_test.exs test/commands/new_test.exs`

Expected: FAIL because the shared parser, ownership helper, `--iso`, and install orchestration do not exist.

- [ ] **Step 6: Implement the shared parser and pending ownership**

Implement `Resolution.parse/1` with `~r/\A([1-9]\d*)x([1-9]\d*)\z/`; convert both captures with `String.to_integer/1` and return `:bad_resolution` for every other input.

Implement `PendingBundle.claim/2` in this exact order:

1. Convert `System.pid/0` to an integer, resolve that integer's process start time before touching the filesystem, and form `%{"pid" => pid, "startedAt" => started}`. The injected and production `process_start/1` functions therefore receive an integer consistently.
2. Enter `deps.with_lock`. The production dependency is `Lock.with_lock/1`, so inspection, stale removal, directory creation, and owner write are serialized with other vzbeam creators.
3. Recheck `Home.exists?(name)` inside the locked callback and return `:exists` before inspecting pending state; the command's earlier check is only a fast-path diagnostic.
4. If no pending directory exists, create it and write the owner.
5. If pending exists but `install-owner.json` is missing or malformed, return `:pending_owner_unreadable` without mutation; absence/corruption is not proof that an installer is dead.
6. If the owner decodes and `deps.process_start.(pid)` returns the recorded start time, return `:creation_in_progress` without mutation.
7. Only when a valid owner's PID/start time no longer matches, remove the stale pending directory, recreate it, and use `AtomicFile.write/2` for the new owner before returning from the locked callback.
8. Normalize `Lock.with_lock/1`'s outer `{:ok, callback_result}` so callers receive exactly `{:ok, %PendingBundle{}}` or `{:error, reason}`; `:exists`, `:creation_in_progress`, and `:pending_owner_unreadable` are always reasons inside `{:error, reason}`.

`cleanup/2` and `promote/2` each reacquire the same host lock, then reread and exactly match the claim's owner map inside the locked callback. Normalize `{:ok, :ok}` from `Lock.with_lock/1` to `:ok` and preserve any `{:error, reason}`. Cleanup removes only that owned pending directory while locked. Promotion rechecks that the final bundle is absent, renames pending to final while the owner is still present, then removes `install-owner.json` from the final directory before releasing the lock. This closes both the half-deleted-owner window and the check-versus-rename race with a second creator.

- [ ] **Step 7: Add CLI parsing, name validation, and mutual exclusions**

Extend strict options with `iso: :string`, `ssh_user: :string`, and `resolution: :string`. Dispatch only these forms:

```elixir
{[name, base], nil, nil} -> clone(name, base, opts, deps)
{[name], image, nil} when is_binary(image) -> restore(name, image, opts, deps)
{[name], nil, iso} when is_binary(iso) -> install_openbsd(name, iso, opts, deps)
```

Return exit 2 for image/ISO, base/ISO, missing media, extra positionals, or malformed sizing/user/resolution before filesystem mutation.

Reject names ending in `.pending` in `validate_name/1`. Validate the user locally, but delegate resolution validation to `Resolution.parse/1` so `new` and `run` cannot drift:

```elixir
defp validate_ssh_user(user) do
  if Regex.match?(~r/\A[a-z_][a-z0-9_-]{0,30}\z/, user) and user != "root",
    do: :ok,
    else: {:error, :bad_ssh_user}
end

defp validate_resolution(nil), do: :ok
defp validate_resolution(value), do: value |> Resolution.parse() |> then(fn
  {:ok, _} -> :ok
  {:error, _} = error -> error
end)
```

- [ ] **Step 8: Implement owned pending work and manifest promotion for all creation paths**

Refactor clone, macOS restore, and OpenBSD install to acquire a `PendingBundle` claim instead of calling unconditional `clear_pending/1`. All three flows use the claim's path, call `PendingBundle.promote/2` only after writing a valid manifest, and call `PendingBundle.cleanup/2` on controlled failure without ever deleting an owner mismatch.

Because the claim directory already exists, clone must copy each top-level base entry into it rather than copying the base directory itself. Enumerate with `File.ls/1`, skip the internal `install-owner.json`, and run the existing clone-copy helper on every other entry:

```elixir
base_dir = Home.bundle_dir(base)
with {:ok, entries} <- File.ls(base_dir) do
  entries
  |> Enum.reject(&(&1 == "install-owner.json"))
  |> Enum.reduce_while(:ok, fn entry, :ok ->
    case cp_rc(Path.join(base_dir, entry), claim.path) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end)
end
```

This preserves all user/runtime bundle files (including OpenBSD `nvram.bin`) without creating `<name>.pending/<base>/...` or overwriting the clone's live owner with a stray owner file left in a completed base. Add that stray-owner case to the clone regression test.

`install_openbsd/4` must resolve defaults, retain the ISO, announce instructions, acquire the claim, create the sparse disk, invoke `deps.install`, write the manifest, and promote the claim. Use this manifest shape:

```elixir
%{"schemaVersion" => 2, "guestOS" => "openbsd", "name" => name, "base" => nil,
  "image" => iso_entry,
  "machineIdentifier" => result.machine_identifier,
  "macAddress" => result.mac_address,
  "sshUser" => ssh_user,
  "cpuCount" => cpu, "memoryBytes" => mem_bytes, "createdAt" => now()}
```

Pass the cached media path, claimed disk/NVRAM paths, CPU, memory, and resolution to `Sidecar.install/2`. Map `:creation_in_progress`, lock errors, and owner mismatches to explicit `new:` messages. The `:pending_owner_unreadable` message must print the exact `<name>.pending` path and tell the operator to verify no old `vzbeam new` is running before removing it. This is also the upgrade path for an ownerless `.pending` directory left by an older vzbeam release. ISO cache acquisition remains before the claim, but no live pending directory is ever cleared.

- [ ] **Step 9: Verify focused and full suites**

Run: `mix test test/resolution_test.exs test/pending_bundle_test.exs test/home_test.exs test/commands/new_test.exs test/iso_cache_test.exs test/sidecar_test.exs`

Expected: PASS with 0 failures.

Run: `mix test`

Expected: PASS with 0 failures.

- [ ] **Step 10: Commit**

```bash
git add lib/vzbeam/pending_bundle.ex lib/vzbeam/resolution.ex lib/vzbeam/commands/new.ex test/pending_bundle_test.exs test/resolution_test.exs test/home_test.exs test/commands/new_test.exs
git commit -m "feat: install OpenBSD interactively from ISO"
```

---

### Task 7: Guest-aware run and cached or one-shot recovery media

**Files:**

- Create: `lib/vzbeam/run_options.ex`
- Create: `test/run_options_test.exs`
- Modify: `lib/vzbeam/commands/run.ex`
- Modify: `test/commands/run_test.exs`

**Interfaces:**

- Produces: `RunOptions.parse/1 :: {:ok, %{name:, gui:, headless:, resolution:, share:, iso: nil | :cached | {:path, String.t()}}} | {:error, atom}`.
- Consumes: normalized manifest guest policy and `IsoCache.resolve_cached/1` or `validate_one_shot/1`.
- Produces guest-aware detached argv for Swift protocol 2.

- [ ] **Step 1: Write the optional-value parser tests**

Create `test/run_options_test.exs`:

```elixir
test "parses normal, cached ISO, and one-shot ISO forms" do
  assert {:ok, %{name: "obsd", iso: nil}} = RunOptions.parse(["obsd"])
  assert {:ok, %{name: "obsd", iso: :cached, gui: true}} = RunOptions.parse(["obsd", "--iso"])
  assert {:ok, %{name: "obsd", iso: {:path, "/tmp/rescue.iso"}, gui: true}} =
           RunOptions.parse(["obsd", "--iso", "/tmp/rescue.iso"])
  assert {:ok, %{name: "obsd", iso: :cached}} = RunOptions.parse(["--iso", "obsd"])
  assert {:ok, %{name: "obsd", iso: {:path, "/tmp/rescue.iso"}}} =
           RunOptions.parse(["--iso", "/tmp/rescue.iso", "obsd"])
  assert {:ok, %{name: "obsd", iso: {:path, "/tmp/rescue.iso"}}} =
           RunOptions.parse(["--iso=/tmp/rescue.iso", "obsd"])
end

test "rejects ambiguous, repeated, and headless ISO input" do
  assert {:error, :iso_headless} = RunOptions.parse(["obsd", "--iso", "--headless"])
  assert {:error, :repeated_iso} = RunOptions.parse(["obsd", "--iso", "--iso"])
  assert {:error, :usage} = RunOptions.parse(["--iso"])
  assert {:error, :usage} = RunOptions.parse(["obsd", "--iso="])
  assert {:error, :usage} = RunOptions.parse(["obsd", "--no-iso"])
  assert {:error, :usage} = RunOptions.parse(["obsd", "extra", "third"])
end
```

Also test option reordering (`--gui obsd --iso /tmp/rescue.iso`), GUI/headless conflict, unknown options, `Resolution.parse/1` rejection, and missing values for `--resolution`/`--share`. Repeated `--share` keeps the existing `OptionParser` last-value behavior; this feature does not introduce an unrelated rejection.

- [ ] **Step 2: Confirm the parser red state**

Run: `mix test test/run_options_test.exs`

Expected: FAIL because `VzBeam.RunOptions` does not exist.

- [ ] **Step 3: Implement the command-specific parser**

Extract `--iso` and `--iso=PATH` before calling `OptionParser`; do not model them as `iso: :boolean`, because `OptionParser` loses repeats without `:keep` and cannot preserve which token lexically followed the flag. Reject `--no-iso`, reject an empty equals value, and count both spellings in the raw argv so any repeated combination returns `:repeated_iso`.

For one bare `--iso`, evaluate these two forms while preserving every other token's order:

1. Cached form: remove only `--iso`; it is valid only if normal option parsing leaves exactly one positional bundle name.
2. Valued form: when the immediate next token exists and is not another option, remove both `--iso` and that token, bind that token as the ISO path, and require normal option parsing to leave exactly one positional bundle name.

Prefer the cached form when it is valid; otherwise use the valued form. This makes `run --iso obsd` cached, while `run --iso rescue.iso obsd` binds `rescue.iso` to the flag rather than swapping name and path. If neither form is valid, preserve a specific mode/resolution error when available and otherwise return `:usage`.

For one `--iso=PATH`, bind the non-empty suffix directly as `{:path, path}`, remove that token, and require the remaining normal parse to produce exactly one bundle name. This matches `new --iso=PATH` rather than creating an avoidable syntax asymmetry.

Parse the ISO-free argv with:

```elixir
OptionParser.parse(args,
  strict: [gui: :boolean, headless: :boolean,
           resolution: :string, share: :string])
```

Require exactly one positional name, reject GUI/headless conflicts, call the Task-6 `Resolution.parse/1` for a supplied resolution, imply GUI whenever media is non-nil, and leave repeated `--share` behavior unchanged.

The normalized map must contain:

```elixir
%{name: name, gui: boolean, headless: boolean,
  resolution: resolution_or_nil, share: share_or_nil,
  iso: nil | :cached | {:path, path}}
```

- [ ] **Step 4: Add failing OpenBSD argv and recovery tests**

Extend `test/commands/run_test.exs` with an OpenBSD fixture containing `guestOS`, ISO digest/file, machine identity, NVRAM, disk, and no hardware model. Capture spawn argv and assert:

```elixir
assert arg_after(argv, "--guest") == "openbsd"
assert arg_after(argv, "--nvram") == Path.join([home, "obsd", "nvram.bin"])
refute "--hardware-model" in argv
refute "--aux" in argv
```

For bare recovery assert cached media appears after `--iso`; for one-shot assert the supplied absolute path appears and the manifest bytes are unchanged after `Run.run/2`. Assert both forms use `--gui`. Add the path-first form `run --iso /tmp/rescue.iso obsd` at the command layer so the parser cannot regress by swapping the bundle and media.

- [ ] **Step 5: Add failing pre-spawn policy tests**

Use a spawn dependency that calls `flunk/1` to prove no spawn for: missing/corrupt cached ISO, missing/empty one-shot ISO, OpenBSD `--share`, ISO with headless, malformed/negated/repeated optional ISO syntax, an unsupported or malformed manifest, and a missing NVRAM file. Assert manifest failures include `Manifest.describe_error/1`. Add capacity fixtures proving two running macOS bundles block another macOS launch while any number of running OpenBSD fixtures do not trigger the engine cap.

The pre-spawn assertion pattern is:

```elixir
never_spawn = deps(fn _argv, _log -> flunk("invalid recovery request spawned sidecar") end)

assert {:error, 1, missing} = Run.run(["obsd", "--iso"], never_spawn)
assert IO.iodata_to_binary(missing) =~ "cached ISO"

assert {:error, 2, share} =
         Run.run(["obsd", "--share", "src=/tmp"], never_spawn)
assert IO.iodata_to_binary(share) =~ "not supported for OpenBSD"

assert {:error, 2, headless} =
         Run.run(["obsd", "--iso", "--headless"], never_spawn)
assert IO.iodata_to_binary(headless) =~ "--headless"
```

For the corrupt-cache case, write bytes whose SHA-256 differs from the manifest digest. For the one-shot cases, create an empty file and use a nonexistent path. Snapshot `config.json` before each call and assert its bytes are identical afterward.

- [ ] **Step 6: Route run parsing and media resolution through policy**

Replace inline `OptionParser` use with `RunOptions.parse/1`. After `Manifest.read_or/2`, reject ISO for macOS and shares for OpenBSD, resolve the selected media, then locate/version-check the sidecar. These checks must precede `Keys.ensure/0` and detached spawn.

Build argv by guest:

```elixir
defp identity_args(%{"guestOS" => "macos"} = m, bundle) do
  ["--guest", "macos", "--machine-id", m["machineIdentifier"],
   "--hardware-model", m["hardwareModel"], "--mac", m["macAddress"],
   "--disk", Path.join(bundle, "disk.img"), "--aux", Path.join(bundle, "aux.img")]
end

defp identity_args(%{"guestOS" => "openbsd"} = m, bundle) do
  ["--guest", "openbsd", "--machine-id", m["machineIdentifier"],
   "--mac", m["macAddress"], "--disk", Path.join(bundle, "disk.img"),
   "--nvram", Path.join(bundle, "nvram.bin")]
end
```

Append `--iso path` only for selected OpenBSD recovery media. Do not write the manifest in any run path.

- [ ] **Step 7: Apply the macOS-only capacity policy**

Change launch to accept the target manifest. Under the existing lock, enforce capacity only when `GuestPolicy.consumes_macos_slot?(target)` is true. Count a running bundle only when its normalized manifest also consumes a macOS slot; ignore unreadable manifests instead of treating them as macOS.

- [ ] **Step 8: Verify parser, run, Swift, and regression suites**

Run: `mix test test/run_options_test.exs test/commands/run_test.exs`

Expected: PASS with 0 failures.

Run: `swift run --package-path swift vzcheck`

Expected: `ALL CHECKS PASS` and exit 0.

Run: `mix test`

Expected: PASS with 0 failures.

- [ ] **Step 9: Commit**

```bash
git add lib/vzbeam/run_options.ex lib/vzbeam/commands/run.ex test/run_options_test.exs test/commands/run_test.exs
git commit -m "feat: boot OpenBSD with optional recovery ISO"
```

---

### Task 8: Pragmatic lifecycle parity

**Files:**

- Modify: `lib/vzbeam/ssh_conn.ex`
- Modify: `lib/vzbeam/commands/{ssh,stop,set,ls,new,ip}.ex`
- Modify: `test/ssh_conn_test.exs`
- Modify: `test/commands/{ssh,stop,set,ls,new,ip,rm,kill}_test.exs`

**Interfaces:**

- Changes: `SshConn.args/2` accepts the per-bundle user.
- Consumes: `GuestPolicy.shutdown_argv/1`, `disk_growth_note/1`, `os_label/2`, and guest-aware re-identification from prior tasks.
- Preserves: IP, force-kill, and removal remain guest-independent.

- [ ] **Step 1: Write failing per-bundle SSH tests**

Change `test/ssh_conn_test.exs` to call `SshConn.args("192.168.64.5", "deploy")` and assert `deploy@192.168.64.5`. Add OpenBSD fixtures with `sshUser: deploy` to SSH and stop tests and assert both commands use that user.

- [ ] **Step 2: Implement stored SSH users**

Change the signature and both callers:

```elixir
def args(ip, user) do
  ["-i", Keys.private(), "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
   "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
   "-o", "ConnectTimeout=5", "#{user}@#{ip}"]
end
```

`Commands.Ssh` and `Commands.Stop` pass `GuestPolicy.ssh_user(manifest)`.

- [ ] **Step 3: Write failing shutdown-policy and SSH-disconnect tests**

Keep the macOS assertion for `sudo -n shutdown -h now`. For OpenBSD assert exact remote argv `doas -n /sbin/shutdown -p now`. Return nonzero SSH statuses containing `doas: Operation not permitted`, `doas: a password is required`, and `doas is not enabled`; assert each error names a narrow `permit nopass <user> as root cmd /sbin/shutdown args -p now` rule plus `vzbeam kill` without entering the reap wait. Retain the existing macOS `sudo: a password is required` and `sudo: a terminal is required` cases.

Add a separate case where SSH returns status 255 with ordinary connection-closed output and the sidecar PID then disappears. Expect `stopped NAME`, not a privilege error. Add the matching timeout case to prove an unrecognized nonzero result still reaps and can time out normally.

- [ ] **Step 4: Implement guest-aware graceful stop**

Run `SshConn.args(ip, user) ++ GuestPolicy.shutdown_argv(m)` and inspect both output and status. Only recognized non-interactive privilege-denial text returns the immediate actionable error. Every other result—including SSH 255 caused by the guest dropping the connection during shutdown—enters the existing PID reap loop. Tailor recognized-denial messages to `sudoers` for macOS and `/etc/doas.conf` for OpenBSD.

Implement the predicate with guest-specific exact substrings rather than `status != 0`: macOS checks `a password is required` and `a terminal is required`; OpenBSD checks `Operation not permitted`, `a password is required`, and `doas is not enabled`.

- [ ] **Step 5: Write failing clone, list, and disk-guidance tests**

Add an OpenBSD base fixture with `disk.img`, `nvram.bin`, cached image reference, and SSH user. Assert cloning:

- copies disk and NVRAM through the existing whole-bundle `cp -Rc` path;
- calls re-identification with `:openbsd`;
- changes generic machine ID and MAC;
- preserves `guestOS`, `sshUser`, and the ISO reference.

Assert `ls` renders `OpenBSD 7.9` for official media and `OpenBSD` for custom media without a version. Add future-schema, unknown-guest, and malformed fixtures: `ls` must retain each row and use `Manifest.describe_error/1` in the OS column, while SSH, stop, set, and IP return command-prefixed versions of the same diagnostic. Assert OpenBSD disk growth text says the host image now has unallocated guest space and directs the user to OpenBSD disk/filesystem tools; retain the recoveryOS text for macOS.

- [ ] **Step 6: Apply guest-aware presentation and growth guidance**

Use `GuestPolicy.os_label(m, m["image"] || %{})` in `Commands.Ls`. When `Manifest.read/1` returns a validation error, build a safe row with `Manifest.describe_error/1` as its OS label instead of replacing the manifest with `%{}`. Replace the single Mac-only `disk_hint` and clone note with clauses over `GuestPolicy.disk_growth_note(manifest)`. Keep disk resizing itself shared and unchanged.

Add matching structured-error clauses to SSH, stop, set, new/clone, and IP. Only `:enoent` maps to “no such bundle”; never collapse an existing unreadable/unsupported `config.json` into absence.

- [ ] **Step 7: Pin unchanged guest-independent commands**

Add one OpenBSD fixture each to IP, rm, and kill tests. Assert IP still uses `macAddress`, rm removes only the bundle and leaves `$VZBEAM_HOME/cache/iso`, and kill signals/reaps the recorded sidecar PID without inspecting guest OS.

- [ ] **Step 8: Verify lifecycle and full suites**

Run: `mix test test/ssh_conn_test.exs test/commands/ssh_test.exs test/commands/stop_test.exs test/commands/new_test.exs test/commands/ls_test.exs test/commands/set_test.exs test/commands/ip_test.exs test/commands/rm_test.exs test/commands/kill_test.exs`

Expected: PASS with 0 failures.

Run: `mix test`

Expected: PASS with 0 failures.

- [ ] **Step 9: Commit**

```bash
git add lib/vzbeam/ssh_conn.ex lib/vzbeam/commands test/ssh_conn_test.exs test/commands
git commit -m "feat: add OpenBSD lifecycle policies"
```

---

### Task 9: Help, operator documentation, and regression verification

**Files:**

- Create: `docs/openbsd.md`
- Modify: `lib/vzbeam/cli.ex`
- Modify: `test/cli_test.exs`
- Modify: `README.md`

**Interfaces:**

- Documents the exact public syntax and the physical-host validation boundary.
- Does not change runtime behavior established by Tasks 1-8.

- [ ] **Step 1: Write failing help-contract tests**

Add assertions to `test/cli_test.exs` for:

```elixir
assert new_help =~ "new <name> --iso PATH"
assert new_help =~ "--ssh-user USER"
assert run_help =~ "run <name> --iso [PATH]"
assert run_help =~ "implies --gui"
assert stop_help =~ "doas -n /sbin/shutdown -p now"
```

Keep the existing pure-ASCII checks.

- [ ] **Step 2: Update top-level and per-command help**

Document local-only OpenBSD media, interactive `halt -p` completion, `admin` default, cached versus one-shot recovery, GUI implication/headless conflict, unsupported OpenBSD sharing, and both macOS/OpenBSD graceful-stop commands. Keep macOS IPSW help unchanged.

- [ ] **Step 3: Create the OpenBSD operator guide**

Create `docs/openbsd.md` with these concrete sections and commands:

```text
Requirements
Verify OpenBSD media
Install: vzbeam new obsd --iso /path/install79.iso
Inside installer: create admin, enable sshd, finish with halt -p
First normal boot and ssh-copy-id
/etc/doas.conf: permit nopass admin as root cmd /sbin/shutdown args -p now
Normal GUI/headless boot
Cached recovery: vzbeam run obsd --iso
One-shot recovery: vzbeam run obsd --iso /path/alternate.iso
Disk growth and OpenBSD guest-side allocation
Unsupported sharing and hardware-validation boundary
```

State that users must verify OpenBSD SHA256/signatures themselves and that recovery media is read-only and detached on the next normal run.

Add an upgrade note: an ownerless `<name>.pending` created by an older vzbeam release is not auto-deleted. The CLI prints its exact path; after verifying no `vzbeam new` process is active, the operator may remove that incomplete directory and retry.

- [ ] **Step 4: Update README navigation and examples**

Change the opening from macOS-only wording to macOS and OpenBSD. Add concise install/recovery examples, link `docs/openbsd.md`, distinguish IPSW cache from ISO cache, and update the validation section to enumerate generic-EFI configuration checks versus physical boot checks.

- [ ] **Step 5: Run all non-booting verification**

Run: `git diff --name-only "$(git merge-base main HEAD)" -- mix.exs '*.ex' '*.exs' | xargs mix format --check-formatted`

Expected: only Elixir files changed on this feature branch are checked, and all are formatted. The repository has no `.formatter.exs`, and unrelated baseline files are not reformatted in this feature.

Expected: exit 0.

Run: `mix test`

Expected: PASS with 0 failures.

Run: `swift run --package-path swift vzcheck`

Expected: `ALL CHECKS PASS` and exit 0.

Run: `mix escript.build`

Expected: exit 0 and a built `vzbeam` escript.

- [ ] **Step 6: Commit**

```bash
git add docs/openbsd.md lib/vzbeam/cli.ex test/cli_test.exs README.md
git commit -m "docs: explain OpenBSD install and recovery"
```

---

### Task 10: Physical Apple Silicon acceptance gate

**Files:**

- Create after execution: `docs/superpowers/results/2026-09-21-openbsd-iso-hardware.md`
- Modify only if hardware exposes a defect: the owning production/test files from Tasks 3-9.

**Interfaces:**

- Consumes the signed sidecar from `mix vz.build`, an official ARM64 OpenBSD 7.9+ `install79.iso`, and a physical Apple Silicon host.
- Produces a factual result document containing host/macOS/OpenBSD versions, exact commands, observed events, passes, failures, and explicitly deferred parity items.

- [ ] **Step 1: Establish the physical-host preconditions**

Run on the physical Mac:

```bash
uname -m
sw_vers
shasum -a 256 /path/to/install79.iso
mix vz.build
```

Expected: `arm64`, supported macOS, a recorded ISO digest that the operator compared with OpenBSD's signed release manifest, and a successfully signed sidecar.

- [ ] **Step 2: Exercise interactive installation**

Run:

```bash
vzbeam new obsd79 --iso /path/to/install79.iso --ssh-user admin
```

In the installer, create `admin`, leave `sshd` enabled, install to the VirtIO disk, and finish with `halt -p`. Expected: the CLI returns success only after power-off; the final bundle contains `config.json`, `disk.img`, and `nvram.bin`; no `.pending` remains.

- [ ] **Step 3: Exercise normal boot, network, SSH, stop, and kill**

Run GUI and headless boots, resolve `vzbeam ip obsd79`, install the generated key with `ssh-copy-id`, add the narrow doas rule, verify `vzbeam ssh`, verify `vzbeam stop`, then boot again and verify `vzbeam kill`. Record all deviations rather than broadening guest privileges.

- [ ] **Step 4: Exercise cached and one-shot recovery**

Run:

```bash
vzbeam run obsd79 --iso
vzbeam run obsd79 --iso /path/to/alternate-arm64.iso
```

For each, verify a GUI opens, install media actually boots (storage array order alone is not proof), the installed disk is visible for repair, guest reboots retain the ISO during that invocation, and guest power-off ends the run. Then run normally and verify no ISO is attached. Confirm the one-shot command did not change `config.json`, persisted `nvram.bin`, or add another cached ISO.

If persistent EFI variables select the installed disk despite ISO-first storage ordering, record that exact observation before changing code. The prescribed fallback is an invocation-only fresh EFI variable store for recovery: copy neither from nor back to bundle `nvram.bin`, pass the temporary path to the existing generic EFI builder, retain it for the sidecar process lifetime, and remove it on exit. Add non-booting argv/configuration and cleanup tests before repeating both recovery commands. Do not change normal boot or installation NVRAM behavior.

- [ ] **Step 5: Exercise clone, set, list, remove, and macOS regression**

Clone the stopped bundle; verify the clone boots with a different generic machine identifier/MAC and inherited SSH/media settings. Grow its disk and confirm the guest sees additional unallocated space. Check `ls`, `ip`, `rm`, and macOS restore/run/share behavior. Confirm two running macOS guests still block a third macOS launch while OpenBSD is not counted by the engine preflight.

- [ ] **Step 6: Record results without claiming unrun checks**

Create `docs/superpowers/results/2026-09-21-openbsd-iso-hardware.md` only from observed evidence. Mark each command PASS, FAIL, or DEFERRED with the reason. If this virtualized development host is the only available machine, do not create a pretend result file; report the physical gate as outstanding.

- [ ] **Step 7: Fix only observed blockers with a regression test first**

For each failure, add the smallest non-booting regression test possible, verify it fails, make the focused fix, re-run `mix test` and `swift run --package-path swift vzcheck`, then repeat the failed hardware step. Use the temporary-variable-store fallback above only if the observed boot selection requires it. Defer an individual parity command when the framework/guest combination is unreliable, but do not weaken installation, normal boot, or recovery acceptance.

- [ ] **Step 8: Commit the factual hardware result and any verified fixes**

```bash
git add docs/superpowers/results/2026-09-21-openbsd-iso-hardware.md
git commit -m "test: record OpenBSD hardware validation"
```

If fixes were required, commit each fix separately before the result document.

---

## Final branch verification

- [ ] Run `git diff --check` and expect exit 0.
- [ ] Run `git diff --name-only "$(git merge-base main HEAD)" -- mix.exs '*.ex' '*.exs' | xargs mix format --check-formatted` and expect exit 0 for every Elixir file changed on this branch; do not reformat unrelated baseline files.
- [ ] Run `mix test` and expect 0 failures.
- [ ] Run `swift run --package-path swift vzcheck` and expect `ALL CHECKS PASS`.
- [ ] Run `mix escript.build` and expect exit 0.
- [ ] Review `git log --oneline` and confirm one focused commit per task.
- [ ] Review `git status --short` and account for every remaining path.
- [ ] State physical hardware results separately from non-booting validation; never infer a successful VM boot from configuration validation.
