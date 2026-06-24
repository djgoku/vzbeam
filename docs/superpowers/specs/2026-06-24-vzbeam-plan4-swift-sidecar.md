# vzbeam — Plan 4 Spec: the Swift `vz` sidecar

- **Status:** Draft — Codex-reviewed (8 findings folded in 2026-06-24); ready for user re-review.
- **Date:** 2026-06-24
- **Nature:** The only component that links `Virtualization.framework`. Builds on the engine from Plans 1–3
  (merged to `main`, 100 tests green). The fake sidecar + the 100-test suite are the **frozen wire-contract
  oracle** the Swift side must match byte-for-byte.
- **Parent design:** `docs/superpowers/specs/2026-06-21-vzbeam-design.md` (§3 layers, §4 wire/identity, §7 CLI,
  §8 run lifecycle, §9 share, §10 provisioning, §12 validated facts, §13 validation-env split).

---

## 1. Summary & scope

Plan 4 builds the Swift `vz` binary: the subcommands **`--version`**, **`reid`**, **`image-info`**,
**`restore`**, **`run`**, plus **provisioning** (`mix vz.build`: compile → ad-hoc-sign → install to
`$VZBEAM_HOME/bin/vz`) and reconciliation of **two engine-side argv seams** that the fake never exercised.

The engine (Plans 1–3) already locates the sidecar (`VZBEAM_VZ` → `$VZBEAM_HOME/bin/vz` → alongside-CLI →
`$PATH`), version-checks it (`vz --version` → protocol 1), and orchestrates every call. Plan 4 makes the
sidecar real and keeps the 100 tests green.

**In scope:** the Swift package; the five subcommands; the `--version` handshake; `mix vz.build`; the two
seam fixes; Swift unit tests + Elixir lockstep tests that run on the build host; a documented HW-gated Mac
integration suite.

**Out of scope (Plan 4):** a `build-sidecar` CLI verb (see §3); any SwiftPM external dependency; an
attached/Port `run` mode; Burrito packaging (§11 of the parent); anything in the parent's §16 non-goals.

---

## 2. The hardware-gated reality & execution model

Plan 4 inverts the Plans 1–3 pattern: the HW-gated work **is** the deliverable.

- **Build host** (this dev box): a macOS guest, `kern.hv_support=0`, `hw.model=VirtualMac2,1`. Swift 6.3.2 +
  CLT + `codesign` present. **Compiles, signs, mints, and reads image metadata — but cannot boot VZ guests.**
- **Mac** (`dj_goku@10.5.0.48`): bare metal, `kern.hv_support=1`, `hv_vmm_present=0`, `hw.model=Mac17,5`,
  macOS 27.0, Swift 6.4 + CLT (SDK 27.0 with `Virtualization.framework` + `AppKit.framework`), Elixir
  1.20.1 / OTP 29 via `mise` (pinned in `mise.toml`). Repo at `~/vzbeam` on `main`. **Boots VZ guests.**

**Execution model:** develop + green-bucket-validate on the build host (fast local edit/compile/test; Swift
compiles + signs here), then **`rsync` the tree to the Mac and run the boot-dependent suite over SSH**. The
sidecar is built + signed **per-machine** (parent §10 already mandates this), so the split is natural, not a
workaround.

**Hardware capability caveat:** the Mac reports `Apple A18 Pro` / `Mac17,5` on a macOS 27 seed build. All
other signals (Mac model id, `hv_support=1`, `hv_vmm_present=0`, the SDK's macOS-guest APIs) say it is a
real, boot-capable Mac and the odd brand string is a beta-OS reporting quirk. We do **not** assume
macOS-guest virtualization works on this chip: the Mac suite is ordered so `restore`
(`VZMacOSRestoreImage.mostFeaturefulSupportedConfiguration`) proves the capability **first and cheaply**. If
it's `nil`, the host can't support the image and we get a clear error rather than a deep failure — at which
point we fall back to another Mac or boot-deferred delivery.

---

## 3. Swift project layout + provisioning

**Package — `swift/` at the repo root, SwiftPM, zero external dependencies.** Links only the system
frameworks `Virtualization`, `AppKit`, `Foundation`.

```
swift/
  Package.swift              # executable target "vz"; .linkedFramework(Virtualization/AppKit)
  vz.entitlements            # com.apple.security.virtualization = true
  Sources/vz/
    main.swift               # dispatch subcommand; setsid() for run; top-level error → stderr + exit
    Wire.swift               # emit(dict) → one compact JSON line + \n + fflush(stdout); log(msg) → stderr
    Args.swift               # tiny flag parser (--k v, bare flags, positional). No swift-argument-parser.
    Version.swift            # {"type":"version","protocol":1}
    ReID.swift               # mint VZMacMachineIdentifier + VZMACAddress
    ImageInfo.swift          # VZMacOSRestoreImage → version/build/url/source
    Restore.swift            # VZMacOSInstaller → progress + restored
    VMConfig.swift           # build & .validate() a VZVirtualMachineConfiguration from argv
    Run.swift                # lifecycle: start, signal trap, delegate, headless RunLoop vs GUI NSApp
```

**Zero-dep is deliberate:** `swift build` then needs **no network** (no SwiftPM package resolution), which
matters because the build host's outbound network is restricted and the Mac's is unknown. The argv is a
handful of flags, so a hand-rolled parser is less risk than a dependency (YAGNI). Each file is one focused
unit.

**Provisioning — `mix vz.build` (a `Mix.Task`), not a CLI verb.** The parent §10 calls provisioning "a
`mix`/make task"; the engine's `run.ex` not-found error currently says `vzbeam build-sidecar`, a verb that
was never built. We reconcile to the `Mix.Task`:

- A `Mix.Task` locates `swift/` reliably via the project root; an escript verb would have to guess from cwd.
- It matches §10 verbatim and keeps the CLI surface minimal (adds no verb).
- Burrito's "no toolchain at runtime" case is explicitly deferred (parent §11); Plan 4 ships **no release
  path**, so there is exactly one not-found message to get right — the dev one — and it changes now.

`mix vz.build` does: `swift build -c release` (streaming output) → **`codesign --force --sign -
--entitlements swift/vz.entitlements <product>`** → install to `$VZBEAM_HOME/bin/vz`. It **re-signs every
build** because `swift build` drops the entitlement on each relink (fact #10). Network-free. Run once per
machine (build host *and* Mac).

**Error-string change (Codex SHOULD-FIX #4):** `run.ex`'s not-found message changes **now**, from
`…(`vzbeam build-sidecar`)` to `…(`mix vz.build`)` (`run.ex:188`). No test currently pins that string
(verified across `test/`), so it is a clean one-line change that supersedes the parent §10 phrasing; it is
exercised by the not-found path + the provisioning smoke-run, not a new assertion.

---

## 4. The frozen wire contract (recap) + per-subcommand emission

**Discipline (`Wire.swift`, shared by all subcommands):** one JSON object per line on **stdout**, newline
terminated, then `fflush(stdout)`. Human logs go to **stderr** only. Nothing else ever writes stdout. This
is what guarantees byte-compatibility with `VzBeam.Protocol` / `VzBeam.Sidecar`. Rules (parent §4): unknown
`type`s are ignored by the engine; an `{"type":"error"}` event or non-zero exit dominates a prior terminal.

Identity ownership (parent §4): Swift **mints + emits** the opaque `machineIdentifier`, `hardwareModel`,
`macAddress`; the engine stores them verbatim and passes them back as inputs. `reid` is a wholesale replace
of `{machineIdentifier, macAddress}` (hardwareModel stays — it's image-bound). Swift never reads or writes
config/state files; it only operates on the disk/aux images it is pointed at.

Argv the engine passes (verified against `lib/vzbeam/sidecar.ex` + the post-seam `run.ex` — see §5):

```
vz --version
vz image-info <latest|PATH>
vz reid
vz restore --ipsw <p> --disk <p> --aux <p> --disk-size <bytes> --cpu <n> --mem <bytes>
vz run --machine-id <b64> --hardware-model <b64> --mac <mac> --disk <p> --aux <p> \
       --cpu <n> --mem <bytes> (--gui|--headless) --resolution <WxH> [--share <tag> <abspath>]
```

---

## 5. The two engine seams + keeping the 100 tests green

Two seams the fake never exercised (parent §"SEAMS"); both resolved engine-side.

**Seam 1 — `run` was missing the identity inputs.** `VZMacPlatformConfiguration` requires
`machineIdentifier` + `hardwareModel`, but `build_argv/5` passed only `--mac`. Per parent §4 ("Swift never
reads config"), the engine passes identity back. Fix: add `--machine-id`/`--hardware-model` (both already in
the manifest).

**Seam 2 — `run` used `--bundle <dir>`, `restore` used explicit `--disk`/`--aux`.** Unify on explicit paths
so Swift never learns bundle layout. Fix: drop `--bundle`; pass `--disk`/`--aux`.

Resulting `build_argv/5` (`lib/vzbeam/commands/run.ex`):
```elixir
[vz, "run",
 "--machine-id", m["machineIdentifier"], "--hardware-model", m["hardwareModel"], "--mac", m["macAddress"],
 "--disk", Path.join(bundle, "disk.img"), "--aux", Path.join(bundle, "aux.img"),
 "--cpu", to_string(m["cpuCount"]), "--mem", to_string(m["memoryBytes"]),
 mode_flag(opts), "--resolution", Defaults.resolve(opts[:resolution], :resolution)] ++ share_args(share)
```

**Lockstep edits to stay at 100 green:**
1. `test/commands/run_test.exs` `make_bundle/1`: add `"machineIdentifier"` + `"hardwareModel"` to the config.
2. **Required acceptance criterion (Codex SHOULD-FIX #6) — a new `run_test` case** whose `spawn` dep captures
   argv and asserts the full expected list, in order:
   `[vz, "run", "--machine-id", <id>, "--hardware-model", <hw>, "--mac", <mac>, "--disk", "<bundle>/disk.img",
   "--aux", "<bundle>/aux.img", "--cpu", <n>, "--mem", <bytes>, "--headless", "--resolution", <WxH>]`; and,
   with `--share tag=/p`, that `["--share", <tag>, <abspath>]` is appended **in that order** (`share_args/1`,
   `run.ex:161`); and that `--bundle` is absent. This is what protects the real Swift contract.
3. `test/support/fake_vz`'s **`run` branch** needs no change — it ignores argv and emits the right events; in
   `run_test` the spawn is faked so `fake_vz` isn't exec'd. (Its **`image-info` branch does change**, for
   `source` — see §6.3.) The fake stays a *wire* oracle, not an argv validator.

No existing test asserts `build_argv` output, so nothing else moves.

---

## 6. Subcommand designs

### 6.1 `--version`
Emit `{"type":"version","protocol":1}`, exit 0. Satisfies `Sidecar.check_version` (`@protocol_version 1`).
Green-bucket.

### 6.2 `reid`
Mint `VZMacMachineIdentifier()` and `VZMACAddress.randomLocallyAdministered()`; emit
`{"type":"reid","machineIdentifier":"<b64 of dataRepresentation>","macAddress":"5e:.."}`, exit 0.
`hardwareModel` is **not** reissued. Synchronous, in-memory. Green-bucket.

### 6.3 `image-info <latest|PATH>`
Emit `{"type":"image","version":"<maj.min.patch>","build":"<buildVersion>","url":"<absoluteString>","source":"<latest|local>"}`, exit 0.
- **PATH:** `VZMacOSRestoreImage.load(from: fileURL)`; `url` is the `file://` URL; `source: "local"`.
- **`latest`:** `VZMacOSRestoreImage.fetchLatestSupported()`; `url` is Apple's CDN URL (the engine `curl`s
  it); `source: "latest"`. Needs network (unreachable on the build host last session) → on failure emit
  `error` + non-zero exit.

Both are async completion-handler APIs → kick off the load, then `RunLoop.main.run()`; the completion
handler emits + flushes + `exit()` (uniform with `restore`/`run`, and avoids any main-queue-handler deadlock
a `DispatchSemaphore` could cause). Green-bucket: shape + error path here; happy path needs a real IPSW.

**`source` semantics (Codex SHOULD-FIX #3).** The engine never branches on `source` (only on the literal
spec), but it *does* persist it into `cache/ipsw/index.json` (`Cache.put_index/2`, `cache.ex:66-70`) and the
bundle's `image` block — so it is recorded metadata, not throwaway display. To keep the fake a **faithful**
oracle, `test/support/fake_vz`'s `image-info` line is updated to emit `source` **per-arg** (`"latest"` for
`latest`, else `"local"`), matching what `cache_test.exs:14,60` already stub. `sidecar_test.exs:29-31`
exercises wrapper pass-through with its own inline stub (`"latest"`) and is unaffected.

### 6.4 `restore` (HW-gated)
Streams `progress`, then `restored`. Flow (`Restore.swift`):
1. `VZMacOSRestoreImage.load(from: ipswURL)` → `mostFeaturefulSupportedConfiguration`. **`nil` ⇒ host can't
   support the image ⇒ `error` + non-zero exit** (the A18/Mac17,5 capability gate — proven first on the Mac).
2. Mint `VZMacMachineIdentifier()` + `VZMACAddress.randomLocallyAdministered()`; `hardwareModel` comes from
   the image requirements (image-bound).
3. Create **aux.img**: `VZMacAuxiliaryStorage(creatingStorageAt: auxURL, hardwareModel:)`. (The engine
   pre-creates the sparse **disk.img**; Swift attaches it and creates only the aux.)
4. Build + `.validate()` a `VZVirtualMachineConfiguration` (platform, `VZMacOSBootLoader`,
   `VZVirtioBlockDevice` on disk.img, cpu/mem clamped to the image's min/max — log to stderr if adjusted).
5. `VZMacOSInstaller(virtualMachine:, restoringFromImageAt:)` → `.install()`; KVO-observe
   `installer.progress.fractionCompleted` → emit `{"type":"progress","fraction":X}` (throttled).
6. Success → `{"type":"restored","machineIdentifier":"<b64>","hardwareModel":"<b64>","macAddress":"5e:..","version":"<maj.min.patch>","build":"<build>"}` → exit 0.

`install()` is async → drive `RunLoop.main.run()` until the handler fires, then exit. **`--disk-size` ownership
(Codex NICE #7): the sidecar must not create or resize `disk.img`** — the engine owns that (`new.ex:65-68`
pre-creates the sparse disk). Swift only attaches the existing disk; it may verify the file's size matches and
emit an `error` on mismatch, nothing more.

### 6.5 `run` (HW-gated; the riskiest piece — Codex review target)
**Startup:** `setsid()` immediately, **in-process and without forking** (the sidecar owns its session; the
engine only `nohup`s it and captures the launch pid via `echo $!` — `daemon.ex:9`, where `nohup` exec's into
`vz` so `$!` *is* `vz`'s pid). Because there is no fork after that point, `getpid()` in the `started` event
equals the captured pid the engine already persists to `vm.pid`; the engine does not read `started.pid`, so
this **no-fork invariant** is what keeps the two in agreement (Codex SHOULD-FIX #5). Then build the config.

**Config (`VMConfig.swift`):**
- platform = `VZMacPlatformConfiguration` from `VZMacHardwareModel(dataRepresentation: b64(--hardware-model))`,
  `VZMacMachineIdentifier(dataRepresentation: b64(--machine-id))`, `VZMacAuxiliaryStorage(url: aux)`.
- `VZMacOSBootLoader`, `cpuCount`, `memorySize`.
- storage `VZVirtioBlockDevice` → disk.img.
- network `VZVirtioNetworkDevice` + `VZNATNetworkDeviceAttachment`, `VZMACAddress(string: --mac)`.
- graphics `VZMacGraphicsDevice` sized from `--resolution WxH` — **attached even headless** (fact #3).
- share (if `--share`) `VZVirtioFileSystemDevice(tag:)` + `VZSingleDirectoryShare(VZSharedDirectory(url:,
  readOnly:false))`.
- GUI adds keyboard + pointing devices. Then `config.validate()` (errors → `error` event + non-zero exit).

**Lifecycle (`Run.swift`):** create `VZVirtualMachine` on the main queue, set delegate, `start()`. In the
completion handler: success → `{"type":"started","pid": getpid()}` (flushed); failure → `{"type":"error",
"domain":"VZErrorDomain","code":N,"message":…}` + exit non-zero (**`code:6` is the 2-VM cap, fact #1** — the
engine maps it). Then keep the main thread alive:
- **headless** → `RunLoop.main.run()` — **never `dispatchMain()`** (fact #2).
- **`--gui`** → `NSApplication` (accessory policy) + a window hosting `VZVirtualMachineView(virtualMachine:)`,
  then `app.run()`. Detached-window-actually-appears is a real-HW check.

**Single terminal-emission path (Codex BLOCKING #1).** All terminal outcomes — `guest_stopped` + `exit(0)`,
or `error` + non-zero exit — go through **one idempotent `finishOnce` closure** guarded by a flag and
dispatched on `.main`, so nothing can double-emit or race two `exit()`s (notably if `vm.stop()` *also* drives
the `guestDidStop` delegate). The **delegate is the canonical emitter** once the VM has actually stopped; the
kill path merely *asks* the VM to stop and lets the same `finishOnce` fire.

**Two stop paths, both resolve through `finishOnce`:**
- **`kill`** (engine sends `SIGTERM`, fact #9): `signal(SIGTERM, SIG_IGN)` + `DispatchSource.makeSignalSource
  (signal: SIGTERM, queue: .main)` whose handler calls `vm.stop()`. `finishOnce` emits `guest_stopped` + exits
  once the VM is stopped (delegate or `stop()` completion, whichever the guard sees first). A main-queue
  signal source fires under `RunLoop.main.run()`/`NSApp.run()` — **this mechanism is validatable on the build
  host** with a dummy no-VM program.
- **`stop`** (engine does guest `shutdown -h now` over SSH, since `requestStop()` is ignored headless, fact
  #4): the `guestDidStop(_:)` delegate fires → `finishOnce` (`guest_stopped` + exit 0). `didStopWithError` →
  `finishOnce` with an `error` event + non-zero exit.

---

## 7. Validation plan

**Green bucket — validated on the build host (evidence before the Mac):**
- The provisioning pipeline end-to-end: `mix vz.build` → `swift build` → `codesign --entitlements` → signed
  `vz` runs → `Sidecar.locate/0` finds it → `check_version` passes.
- `reid` real minting; emit shape; engine `reid` wrapper parses it.
- `image-info` JSON shape + error path (load a non-IPSW → graceful `error`).
- **Async-queue probe (Codex NICE #8):** a small Swift program logs which thread/queue the `image-info`
  (local-error) and `restore` (failure) completion handlers fire on, and asserts the JSON line is flushed
  before `exit()` — confirming the `RunLoop.main.run()` + exit-from-handler pattern can't strand a handler or
  drop buffered stdout.
- `--share` tag rules via `VZVirtioFileSystemDeviceConfiguration.validateTag` (static, no VM).
- The SIGTERM→`stop()` signal mechanism (and the `finishOnce` guard) under `RunLoop.main.run()` (dummy
  no-VM program).
- The 100 Elixir tests stay green + the escript `run`→`kill` smoke against the real `fake_vz`.

**HW-gated — the documented Mac suite, run over SSH (rsync → Mac → execute), ordered to de-risk capability
first:**
1. `mix vz.build` on the Mac.
2. `vz image-info` (local IPSW / `latest`).
3. `vzbeam fetch …` → cache an IPSW.
4. `vzbeam new base --image …` → **`restore`** — the capability moment.
5. `vzbeam run base --gui` → **first boot + Setup Assistant** — ⚠️ **manual checkpoint** (window on the Mac's
   display: create `admin`, enable Remote Login, run the one-time `ssh-copy-id`).
6. `vzbeam new dev base` (clone + `reid`) → `vzbeam run dev` (headless) → `ip`/`bridge100`/`ssh`.
7. `ssh -- cmd` one-shot + interactive; `--share` virtiofs round-trip. Confirm `started.pid` == the bundle's
   `vm.pid` (the no-fork invariant, §6.5).
8. `stop` (graceful→`guestDidStop`→exit0); `kill` (SIGTERM→`stop()`→single `guest_stopped`→exit0); confirm
   exactly **one** terminal event per stop (the `finishOnce` guard).
9. **2-VM cap — two distinct checks (Codex BLOCKING #2):**
   - (a) **engine pre-check:** with two live pidfiles, a 3rd `vzbeam run` returns `:at_capacity` *without
     spawning the sidecar* (`run.ex:44-46`). This is the UX pre-check, not the framework path.
   - (b) **framework-authoritative `VZError 6`:** with two VMs actually running, invoke `vz run` **directly**
     (bypassing the engine's `count_running/0`) against a 3rd bundle, and confirm `start()` yields
     `VZErrorDomain code 6`, emitted as an `error` event and mapped by the engine to its cap error.
   Then `rm` cleanup.

Results are captured into a results doc so the HW-gated definition-of-done is on the record.

**Manual checkpoint:** step 5 (first-boot Setup Assistant) is inherently manual GUI on the Mac (parent §8);
everything after a configured base is SSH-automatable.

---

## 8. Testing strategy

- **Swift unit tests (build host, `swift test`):** `Args` parser; `Wire` emits exactly-one-line compact JSON
  the `Protocol` decoder accepts (cross-checked by piping `vz` output through the engine decoder); `reid`
  minting; `image-info` shape/error; `validateTag` rules; the async-queue + flush-before-exit probe (§7).
  XCTest via `swift test` works under CLT (no full Xcode).
- **Elixir lockstep tests (build host):** the `build_argv` argv assertion (§5 item 2, required); updated
  `make_bundle`; the `fake_vz` `image-info` `source` change (§6.3). The error-string change pins no test
  (none exists). Suite stays at 100.
- **HW-gated integration (Mac, over SSH):** the §7 suite. Documented and re-runnable; not green-bucket TDD.

---

## 9. YAGNI / Plan-4 non-goals (on the record)

- **No `build-sidecar` CLI verb** — `mix vz.build` is the single provisioning entry (§3).
- **No SwiftPM external dependency** — hand-rolled `Args`, system frameworks only (§3).
- **No attached/Port `run` mode** — `run` always detaches (parent §8/§16).
- **No catalog mirroring / checksum-from-image** — `image-info latest` is best-effort; cache size-sanity
  stays as in Plan 2/3.
- **No Burrito/release provisioning** — deferred (parent §11). The dev not-found message *is* updated now to
  `mix vz.build` (§3); only a future release-specific message would be packaging-milestone work.

---

## 10. Risks & open items

- **A18/Mac17,5 capability** (§2) — de-risked first via `restore`'s `mostFeaturefulSupportedConfiguration`.
- **Detached GUI window** — a `setsid`'d process showing an AppKit `VZVirtualMachineView` window is a
  real-HW check; may need `setActivationPolicy` + `activate`. Verified in suite step 5.
- **`image-info latest` network** — Apple's catalog was unreachable from the build host; the Mac's
  reachability is unknown. Local-PATH is the always-available path.
- **Signal-source-under-RunLoop + `finishOnce`** — the mechanism is validated on the build host; its
  interaction with a *live VM's* `stop()`/`guestDidStop` (single terminal event) is confirmed in suite step 8.
- **`VZError 6` reachability** — only observable by bypassing the engine pre-check; suite step 9(b) does this
  with a direct `vz run`.
- **First-boot manual checkpoint** — requires hands at the Mac (§7 step 5).

---

## 11. Codex review (2026-06-24)

Independent adversarial design review (session `019efbed-13d1-70b1-8c9f-596499779ea8`). All 8 findings folded
in: BLOCKING #1 single `finishOnce` terminal path (§6.5); BLOCKING #2 split cap validation (§7 step 9);
SHOULD-FIX #3 `source` semantics + faithful fake (§6.3); #4 provisioning/error-string wording (§3/§9); #5
no-fork pid invariant (§6.5); #6 required argv test with exact list (§5 item 2); NICE #7 `--disk-size`
verify-only (§6.4); #8 async-queue/flush probe (§7/§8).

---

## 12. References

- Parent design: `docs/superpowers/specs/2026-06-21-vzbeam-design.md` (§3/§4/§7/§8/§9/§10/§12/§13).
- Plan 3 (engine `run`/`stop`/`kill`/`ssh` this consumes):
  `docs/superpowers/specs/2026-06-24-vzbeam-plan3-run-lifecycle.md`,
  `docs/superpowers/plans/2026-06-24-vzbeam-run-lifecycle.md`.
- Engine code to match: `lib/vzbeam/sidecar.ex`, `lib/vzbeam/protocol.ex`, `lib/vzbeam/commands/run.ex`
  (`build_argv`), `lib/vzbeam/commands/new.ex` (restore deps), `lib/vzbeam/cache.ex` (`source`/`url` usage),
  `lib/vzbeam/daemon.ex` (launch-pid capture).
- The wire oracle: `test/support/fake_vz`.
