# vzbeam — Plan 3 (run lifecycle) handoff (paste into a fresh session)

You are continuing **vzbeam**, a tool that spins up throwaway **macOS** VMs on Apple Silicon built
directly on Apple's **Virtualization.framework** (no third-party runtime, no paid Apple Developer
account). It is split into a **minimal Swift `vz` sidecar** (the only code that links VZ — still not
built; that's Plan 4) and an **Elixir CLI engine**. This is the **same repo** — Plans 1 and 2 are
merged to `main`, so **read the spec, plan, and code rather than taking anything below on faith**
(validate, don't assume).

Three memory files auto-load for this project: `vzbeam-validation-environment`,
`vzbeam-collaboration-style`, `vzbeam-plan-progress`. Read them.

## Your mission

**Brainstorm, then (after we agree on a spec + plan) implement Plan 3 — the run lifecycle:** the verbs
`run`, `stop`, `kill`, `ssh`, plus the host-wide concurrency lock and the 2-VM cap. Do **not** write
product code during brainstorming. Start with the `brainstorming` skill, confirm a spec and plan with
me, then execute via subagent-driven-development.

## What's already on `main` (Plans 1 & 2 — don't re-create)

The Elixir engine, fully tested (`mix test` → 66 green; `mix escript.build` → `./vzbeam`). Build on
these **realized** module interfaces (verify in `lib/vzbeam/`):

- `VzBeam.Home` — `root/0`, `bundle_dir/1`, `bundles/0` (ignores `*.pending`), `exists?/1`
- `VzBeam.Defaults` — `values/0`, `resolve/2`, `describe/0` (cpu/mem_gb/disk_gb/resolution/ssh_user; no config file)
- `VzBeam.Manifest` — `read/1`, `write/2` (atomic via `AtomicFile`)
- `VzBeam.Pidfile` — `read/1`, `write/2` (stores **integer** pid; coerces string input), `running?/1`
  (pid alive AND `ps` start-time match), `process_start/1`. `vm.pid` JSON `{pid, startedAt, bundle}`.
- `VzBeam.Leases` — `parse/1`, `lookup_ip/2`, `read/0`
- `VzBeam.AtomicFile` — `write/2` (mkdir_p + temp + rename)
- `VzBeam.Protocol` — `decode_line/1`, `collect/3 :: (lines, terminal_types, final_newline?)` — pure
  JSON-lines decoder; **error-event > terminal** precedence; oversize/unterminated/no-terminal guards.
  **Plan 3 likely needs a streaming collector fed by a `Port` (today it's list-based).**
- `VzBeam.Sidecar` — `locate/0` (env `VZBEAM_VZ` → `$VZBEAM_HOME/bin/vz` → alongside-CLI → `$PATH`),
  `check_version/1`, `call/3` (captured `System.cmd`, injectable runner), `image_info/2`, `restore/2`,
  `reid/2`. **`call/3` is captured + BEAM-owned — it is NOT how `run` spawns** (run must detach; below).
  Transport precedence in `call/3`: error-event > non-zero exit > terminal.
- `VzBeam.Cache` — `ensure/2` (idempotent/self-healing; injectable image_info/download/copy), `list/0`,
  `lookup/1`, `dir/0`
- `VzBeam.Table` — `render/1` (shared table renderer; `Ls`/`Images` use it)
- `VzBeam.CLI` — `run/1` dispatch + `@usage`. **Plan 3 adds `run`/`stop`/`kill`/`ssh` clauses.**
- `VzBeam.Commands.{Ip, Ls, Fetch, Images, New, Rm}` — the verb pattern: `run/1` → `run/2` (or a `deps`
  map) with **injectable** side-effects; returns `{:ok, iodata} | {:error, code, iodata}`.

Bundle/manifest model (spec §5): a bundle dir `$VZBEAM_HOME/<name>/` holds `config.json`, `disk.img`,
`aux.img`, `vm.pid` (while running), `run.log`. Host-level: `run.lock`, `keys/id_ed25519[.pub]`,
`cache/ipsw/`, `bin/vz`.

## What Plan 3 builds (spec §7, §8)

- `run <name> [--gui|--headless] [--resolution WxH] [--share tag=/path]` — boot the VM; **always
  detaches/backgrounds** (`--gui` merely adds a window). Spawn `vz run` in its **own session**,
  stdin/stdout/stderr → `run.log` (never a live pipe), survive the escript exit, ignore SIGHUP. **Tail
  `run.log` for a bounded startup handshake** (`started` → capture pid / `error` / timeout), then
  atomically write `vm.pid`.
- `stop <name>` — graceful: guest-side `shutdown -h now` over SSH (macOS ignores `requestStop()`
  headless — fact #4); the sidecar's `guestDidStop` exits 0.
- `kill <name>` — force: the engine **sends a signal** to the `vz run` pid (sidecar traps →
  `VZVirtualMachine.stop()`). **Never hard-`pkill`** (fact #9); `SIGKILL` last-resort only. No new Swift
  subcommand — signals are the control path.
- `ssh <name> [-- cmd…]` — thin key-based SSH: resolve IP (leases by MAC) + baked key; document the
  one-time `ssh-copy-id` key-install + `mount_virtiofs` flow.
- **Concurrency & the 2-VM cap:** a host-wide `$VZBEAM_HOME/run.lock` (flock) wraps **cap-check →
  spawn → `vm.pid` write** as one critical section; live pids re-counted *inside* the lock to defeat
  TOCTOU. `VZError Code=6` is authoritative and always maps to the same typed cap error (fact #1); the
  pre-check is UX-only.
- Also lands the transport upgrades **deferred from Plan 2**: `Port`-streamed `restore` progress, and
  the stderr → `run.log` capture.

## The load-bearing strategy (unchanged): build against the FAKE sidecar

`run`/`stop`/`kill` still can't use the real Swift `vz` (Plan 4). Extend the fake `vz`
(`test/support/fake_vz`) to support `run` — emit `{"type":"started","pid":…}`, then
`{"type":"guest_stopped"}`, exit 0 — plus a long-running mode for the detach harness. **The
detached-spawn + run.log-tailing + run.lock mechanics are green-bucket-testable here with a dummy
long-running child (spec §13).** Real boot is HW-gated.

Protocol events Plan 3 consumes (spec §4): `run` → `{"type":"started","pid":4321}` …
`{"type":"guest_stopped"}` → exit 0; errors `{"type":"error","domain":…,"code":…,"message":…}`.

## Open design questions to spike during brainstorming (validate, don't assume)

1. **macOS detach mechanism.** Spec §8 says "own session (`setsid`)", but **macOS may not ship
   `setsid(1)`** — spike how to spawn a child that (a) survives the escript/BEAM exit, (b) gets its own
   session, (c) ignores SIGHUP, (d) redirects stdio → `run.log`, from Elixir on macOS. Candidates:
   `nohup`, a `sh -c` wrapper, `posix_spawn` w/ `POSIX_SPAWN_SETSID` inside the sidecar, a double-fork.
   **Green-bucket spikeable now with a dummy child.**
2. **Host-wide lock.** `run.lock` across the cap-check→spawn→vm.pid critical section — but **macOS may
   not ship `flock(1)`**; spike Elixir-native file locking (`:file` advisory locks? an `O_EXCL`
   lockfile? an `flock(2)` path?). Must survive a crashed holder (stale-lock recovery).
3. **`Port`-streamed `restore`.** Swap the captured `Sidecar.call/3` to a `Port` (`{:line, N}` +
   `:exit_status`) for `restore` so progress streams; feed `Protocol` line-by-line. `run` is **not** a
   Port (it detaches).
4. **`run.log` startup handshake.** Bounded tail-for-`started`/`error`/timeout — poll vs `Port`
   `tail -f` vs `File.stream!`. Decide the timeout and what a timeout means for `vm.pid`.
5. **SSH key baking.** Spec §5 has `keys/id_ed25519[.pub]`. When/where is the keypair generated (first
   run? a setup step?) — `stop`/`ssh` depend on it. Decide.
6. **`--share` virtiofs** (spec §9): Elixir parses + validates `tag=/path` (tag ≤ 36 UTF-8 bytes, host
   dir exists), passes `tag` + absolute path to Swift. First-class, tested MVP feature.

## Validated facts / gotchas Plan 3 must respect (spec §12, §8)

- ≤ 2 macOS VMs; a third fails `VZError Code=6` → typed cap error (fact #1).
- Headless networking needs `RunLoop.main.run()`, not `dispatchMain()` (fact #2); a graphics device is
  attached even headless (fact #3). (Swift/Plan 4 — but the engine must not assume otherwise.)
- macOS ignores `requestStop()` headless → guest `shutdown -h now` + `guestDidStop` exit (fact #4) →
  drives `stop`.
- `bridge100` is the networking-readiness tell (fact #8) — don't conclude "broken" from a too-short
  SSH poll. Lifecycle: `starting → started → networking(bridge100) → ssh_ready`.
- **Never hard-`pkill` a running guest** (fact #9) → `kill` sends a trappable signal first.

## Carry-forwards / deferred (from Plan 2 reviews — not bugs)

- **erlexec/muontrap** were evaluated and rejected for the escript phase (the native `priv` binary
  can't be spawned from an escript — spike-proven; surmountable via `:exec.start(portexe:)` +
  provisioning like `vz`, but unneeded for Plan 2's short captured calls). **Revisit for `run`/`kill`**
  if a concrete need appears (or under Burrito) — don't re-litigate; see Plan-2 spec §2.
- Cache **size/checksum validation** deferred until the protocol carries a size (real download).
- **Test-realism (learned the hard way):** an injected dir-creating fake `copy` masked a real `Cache.acquire` mkdir-ordering bug (fixed post-merge, `3fb676b`) — it only surfaced by *running the escript* (`./vzbeam fetch`), not the green suite. For Plan 3's filesystem/OS-heavy paths, exercise the **real** syscall/filesystem in tests and smoke-run the escript; don't trust forgiving fakes.
- Assorted Minor cosmetic/coverage nits — non-bugs.

## Validation environment reality (critical)

This build host is a **virtualized** macOS box (`kern.hv_support=0`) and **cannot boot VZ guests**. So:
- **Green bucket (test here):** the detached-spawn daemonization harness (dummy child: survives parent
  exit, ignores SIGHUP, `run.log` redirect), `run.lock`/cap-counting under the lock, the `run.log`
  startup-handshake tailing, the `Port`-streamed protocol decode, fake-`vz` `run`/`stop`/`kill`
  orchestration, `ssh` IP resolution, `--share` parse/validate.
- **Needs bare-metal Apple Silicon:** the *real* `run`/boot, the AppKit window, the 2-VM cap (`VZError
  6`), headless `RunLoop` networking, `bridge100`, real `stop`/`kill`, full first-boot. A green
  `mix test` does not exercise booting.
- Toolchain: Elixir 1.20.1 + Erlang/OTP 29 via `mise`; `mix` on `$PATH`. Hex reachable; Apple
  IPSW/catalog endpoints untested.

## How to work (project conventions)

- **Brainstorm → spec (`docs/superpowers/specs/`) → `writing-plans` → subagent-driven execution →
  per-task + whole-branch reviews → `finishing-a-development-branch`.** Confirm the spec and plan with
  me before building.
- **Validate, don't assume.** Prove framework/OS/tooling behavior with a minimal, non-mutating spike
  before relying on it (especially the detach + lock mechanics). State what's validated vs open.
- **Resolve mechanical forks yourself via spike + a recommendation** — don't poll me with
  multiple-choice questions the spec or a quick spike can settle; reserve questions for genuine
  product/scope calls.
- **Use Codex as an independent review point** at the spec milestone and on the riskiest mechanism (the
  detach/lock) before it hardens — I want Codex in reviews.
- **YAGNI hard** — minimal verb surface; ask before adding extras.
- Branch off `main`; per-task TDD commits; merge (`--no-ff`) only when I approve.

## References

- Design spec: `docs/superpowers/specs/2026-06-21-vzbeam-design.md` — esp. **§4** (wire protocol),
  **§5** (data model), **§7** (verbs), **§8** (run lifecycle — the heart of Plan 3), **§9** (virtiofs
  share), **§12** (validated facts), **§13** (validation env), **§16** (deferred non-goals).
- Plan 2 spec + plan (mirror the module-shape + TDD-task style):
  `docs/superpowers/specs/2026-06-23-vzbeam-plan2-image-clone.md`,
  `docs/superpowers/plans/2026-06-23-vzbeam-image-clone.md`.
- Code: `lib/vzbeam/` on `main`. Fake sidecar: `test/support/fake_vz`. README: `README.md`.

## Start by

Invoking the `brainstorming` skill and working the open questions with me — chiefly the **macOS detach
mechanism** and the **host-wide lock** (both green-bucket spikeable now), then the `run`/`stop`/`kill`/
`ssh` shapes and the `Port`-streamed transport. Then propose a spec, then a plan. Keep it minimal;
**confirm with me before writing product code.**
