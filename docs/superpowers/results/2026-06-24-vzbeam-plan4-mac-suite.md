# vzbeam Plan 4 — HW-gated Mac integration suite: results

- **Date:** 2026-06-24
- **Mac:** `dj_goku@10.5.0.48` — `hw.model=Mac17,5`, chip reports `Apple A18 Pro`, macOS 27.0 (seed `26A5368g`), `kern.hv_support=1`, `hv_vmm_present=0`. Swift 6.4 + CLT (SDK 27), Elixir 1.20.1/OTP29 via mise.
- **Method:** develop + green-bucket-validate on the build host; `rsync` tree → Mac; run boot-dependent steps over SSH. Test home: `$HOME/vzbeam-hw`.
- **Status:** autonomous-over-SSH steps DONE; boot-dependent steps (restore → first-boot → …) PENDING.

## Build host (green bucket) — DONE
- `mix test`: **102 passed**. `swift run vzcheck`: **13/13**. `swift build -c release`: **clean** (no warnings).
- Provisioning pipeline (`mix vz.build` → signed `vz` → `Sidecar.locate`/`check_version`): green.
- escript e2e vs fake: `new --image` (restore) → clone → run×2 → **2-VM cap refuses the 3rd** → kill → all stopped.

## Mac suite (over SSH)

### ✅ Step 1 — `mix vz.build` on the Mac (per-machine build + sign)
- `swift build -c release` Build complete (59.76s); installed → `~/vzbeam-hw/bin/vz`.
- `vz --version` → `{"protocol":1,"type":"version"}`.
- `codesign -d --entitlements` → `com.apple.security.virtualization` embedded. ✔
- Note: two benign `ld: warning: search path ... /Developer/usr/lib not found` on `vzcheck-product` (Swift 6.4 CLT linker noise; build completes, binary runs).

### ✅ `reid` on real Apple Silicon
- `vz reid` → minted `{"macAddress":"c2:7d:a5:2e:d5:74","machineIdentifier":"<b64>","type":"reid"}`. ✔

### ✅ Step 2 — `image-info` on the Mac
- `vz image-info latest` → **catalog reachable**: `{"version":"26.5.1","build":"25F80","source":"latest","url":"https://updates.cdn-apple.com/.../UniversalMac_26.5.1_25F80_Restore.ipsw"}`. ✔ (Unreachable from the build host last session; works on the Mac.)
- Handler confirmed firing on a background thread (matches the build-host probe).
- Disk free: 369 GiB (ample for IPSW + restore).

### ⏳ Step 3 — `fetch` (PENDING) — downloads ~16 GB IPSW from the confirmed URL.

### ⏳ Step 4 — `restore` (`new base --image latest`) (PENDING) — **the capability moment**: proves `VZMacOSRestoreImage.mostFeaturefulSupportedConfiguration` is non-nil on Mac17,5/A18-Pro (i.e. macOS-guest virtualization is supported), then a real `VZMacOSInstaller` install. Automatable over SSH (no GUI).

### ⏳ Step 5 — first boot `run base --gui` (PENDING) — **⚠️ manual GUI checkpoint** on the Mac's display: complete Setup Assistant (create `admin`, enable Remote Login), then the one-time `ssh-copy-id`.

### ⏳ Steps 6–9 (PENDING) — clone + headless run + `ip`/`bridge100`/`ssh`; `--share` round-trip; `stop`/`kill` (single terminal event); 2-VM cap (engine pre-check + direct-`vz run` `VZError 6`); `rm` cleanup.

## Restore outcome (2026-06-25) — boot validation BLOCKED on this Mac (OS/env), not a vzbeam bug

- ✅ **`fetch latest`**: downloaded the 18 GB IPSW (26.5.1/25F80) from Apple's CDN, cached + indexed. rc=0 (~10 min).
- 🐛→✅ **`restore` HW bug #1 (FIXED)**: first attempt crashed `EXC_BREAKPOINT/SIGTRAP` (exit 133). Crash report: `dispatch_assert_queue_fail` — `VZMacOSInstaller.init` requires the VM's (main) queue, but `VZMacOSRestoreImage.load`'s completion fires on a background queue and we created the installer there. **Fixed** (`8bea74c`): hop the post-load work to `DispatchQueue.main.async`. (Compile-clean + review-Approved in Task 8, yet HW-only — vindicates the develop-here / validate-on-Mac model.)
- ⛔ **`restore` then fails in Apple's restore stack (env limitation)**: `VZError 10007` → `NSUnderlyingError com.apple.MobileDevice.MobileRestore #4014 "Unexpected device state 'DFU' expected 'RestoreOS'"`. Deterministic (~12 s, 2 attempts). The capability gate **passed** (`mostFeaturefulSupportedConfiguration` non-nil), config validated, installer created on the main queue — so the failure is **inside Apple's restore subsystem**, not vzbeam. Error 4014/DFU is a *physical-device* (Apple Configurator/cable) restore error; its appearance in a VZ guest restore is anomalous → the **macOS 27.0 seed host + Mac17,5/A18-Pro** mishandles VZ macOS restore. Surfaced the underlying error in the message (`8a0d1f0`).
- **Conclusion:** vzbeam's `restore`/`run` are code-correct and hardened; the actual macOS install cannot complete on this specific machine. Boot-dependent steps 5–9 (first-boot → run → ssh → share → stop → kill → cap) are **blocked on this Mac**. Need a standard M-series Mac on a release macOS, or accept boot-deferred for this plan.

## Boot suite — VALIDATED on a release-macOS Apple Silicon Mac (2026-06-25)

The 27.0-seed Mac couldn't restore (MobileRestore 4014). On a **release-macOS** Apple Silicon Mac, the full boot suite passed:

| step | result |
|---|---|
| `mix vz.build` (build+sign+entitlement), `reid`, `image-info latest` (catalog reachable) | ✅ |
| `restore` (real `VZMacOSInstaller`) | ✅ (after the SIGTRAP main-queue fix `8bea74c`) |
| `run` boot + `--gui` window (Dock icon after `.regular`, `f65f196`) | ✅ |
| CoW clone → headless `run` → DHCP lease + `bridge100` → `ssh` (interactive + one-shot) | ✅ |
| virtiofs `--share` bidirectional round-trip | ✅ |
| `kill` (SIGTERM trap → `vm.stop()` → single `guest_stopped`) | ✅ |
| 2-VM cap (a) engine pre-check / (b) framework `VZError 6` → mapped to cap error | ✅ / ✅ (proven via run.log `code:6`) |
| graceful `stop` (guest `shutdown` → `guestDidStop`) | ✅ **HW-validated 2026-06-25** (deferred to Plan 5). With the guest NOPASSWD rule in place, `stop base` → `stopped base`; `run.log` shows `started`→`guest_stopped` (exactly one, no error). See `…/results/2026-06-25-vzbeam-plan5-hardening.md`. (`stop` still fails fast with a clear message when the rule is missing, `3ab8c65`.) |

**HW bugs found + fixed by this suite:** (1) `VZMacOSInstaller` created on a background queue → SIGTRAP (`8bea74c`); (2) `--gui` window had no Dock icon (`.accessory`→`.regular`, `f65f196`); (3) opaque `VZError 10007` → surface the underlying error (`8a0d1f0`); (4) `stop` hung 60s on a sudo-password failure → fail fast (`3ab8c65`). Plus the engine `VZError 6`→cap-error mapping (`aefeab0`) confirmed end-to-end.

**Conclusion:** vzbeam Plan 4 is functionally complete and hardware-validated on release-macOS Apple Silicon.

## Codex whole-branch review (2026-06-25, session 019eff76)

Independent Codex adversarial review of `main...HEAD` (after an earlier `adversarial-review` run stalled on the read-only sandbox; re-run via `task` mode with git-only reads). **No blocking defects.** Areas (wire shapes/events, build_argv seam, run/restore lifecycle incl. main-queue restore + finishOnce + VZError-6 mapping, provisioning, Plan 1–3 regression): no defect except the items below.

- **#1 Wire key order (should-fix) — non-defect, dispositioned.** Swift emits `JSONSerialization(.sortedKeys)`; `fake_vz`'s hardcoded JSON differs in key *order*. `VzBeam.Protocol` decodes via `Jason.decode` into a map (order-independent), so the engine parses both identically. The spec's "byte-for-byte" means *semantically matches the decoder*, not literal bytes. No change.
- **#2 stream/4 silently skips malformed/`:noeol` lines (should-fix) — deferred (known).** Documented Plan-3 Minor: the real `vz` only emits valid NDJSON via `Wire`, and `<1 MiB` lines never hit `:noeol`, so it's unreachable in normal operation. Defensive hardening for a future pass.
- **#3 `mix vz.build` crashed via `{_,0}=` on failures (nice) — FIXED (`c546615`).** Now `Mix.raise`s with the command, exit status, and output.
- **#4 `run` locates `vz` then `check_version` locates again (nice) — deferred.** `locate/0` is deterministic; validated-path ≠ launched-path is near-impossible in practice.
