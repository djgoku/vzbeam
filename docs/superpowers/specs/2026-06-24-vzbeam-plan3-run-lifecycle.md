# vzbeam — Plan 3 Design: run lifecycle (`run` / `stop` / `kill` / `ssh` + lock + 2-VM cap)

- **Status:** Draft for review (spikes folded in 2026-06-24; Codex pass pending)
- **Date:** 2026-06-24
- **Scope:** Implementation-level design for Plan 3. Fills the *module-level* gaps the MVP design spec
  (`2026-06-21-vzbeam-design.md`) leaves open in §8 (run lifecycle), §9 (share). Behavior is governed
  by that spec; this doc settles module shapes, the detach + lock mechanics, the streaming transport,
  and the test seams.
- **Premise:** the Swift `vz` sidecar does not exist yet (Plan 4). Plan 3 builds the Elixir
  orchestration against an extended **fake `vz`** (`test/support/fake_vz`). The **detach harness, the
  host-wide lock, the cap counting, the `run.log` handshake, the `Port`-streamed decode, the SSH key +
  IP resolution, the interactive-ssh tty hand-off, and `--share` parse/validate are all real and tested
  here**; only the actual hypervisor boot is HW-gated. See §13 of the MVP spec for the green-bucket /
  bare-metal split.

---

## 1. Scope

**Verbs** (added to `VzBeam.CLI.run/1` + `@usage`):

- `run <name> [--gui|--headless] [--resolution WxH] [--share tag=/path]` — boot the VM; **always
  detaches** (`--gui` only adds a window). Default `--headless`. Single `--share` for the MVP.
- `stop <name>` — graceful guest `shutdown -h now` over SSH.
- `kill <name>` — force power-off via a trappable signal to the `vz run` pid.
- `ssh <name> [-- cmd…]` — interactive shell **and** one-shot command, key-based.

**New modules:** `VzBeam.Lock` (host-wide advisory lock), `VzBeam.Daemon` (detached spawn + pid
capture), `VzBeam.Keys` (baked SSH keypair), `VzBeam.Share` (`--share` parse/validate); plus verb
modules `VzBeam.Commands.{Run,Stop,Kill,Ssh}`.

**Extended module:** `VzBeam.Sidecar` gains `stream/4` (a `Port`-driven streaming collector for live
`restore` progress + a stderr tail) — the two transport carry-forwards deferred from Plan 2.

**Carry-forwards landed here (from Plan 2 reviews):**
- `Port`-streamed `restore` progress (Plan 2 used captured `System.cmd`; spike-proven streamable).
- Sidecar **stderr-tail capture** on failure (`run`'s stderr → `run.log` via the detach redirect;
  `restore`'s stderr → a temp file, tail surfaced on error).

**Deferred (decided this session):**
- **`rm --force` (stop-then-delete)** — explicitly kept deferred. `rm` continues to refuse a running
  bundle (Plan 2 behavior). A later slice can add `--force` now that `stop`/`kill` exist.
- **Multiple `--share` mounts** — single share for the MVP (YAGNI; add when a real need appears).
- **`caffeinate`-wrapping** a long-running VM against host sleep — noted (the binary exists) but out of
  scope until host-sleep-pausing-a-VM is a demonstrated problem.

**Faked now, validated on bare-metal Apple Silicon later (MVP §13):** the real boot, the AppKit
window, the live 2-VM cap (`VZError 6`), headless `RunLoop` networking, `bridge100`, real `stop`/`kill`
of a guest, and a real `ssh` into a booted VM. A green `mix test` proves the orchestration, not the
hypervisor.

---

## 2. Evidence from spikes (this design is grounded in these, not assumed)

Run on this host (macOS 26.5.1, Elixir 1.20.1 / OTP 29), throwaway non-mutating harnesses:

- **`setsid(1)` and `flock(1)` are both ABSENT on macOS** (`command -v` → not found). The MVP spec
  named both (§8); neither exists, so the literal mechanisms must be replaced. Present and usable:
  `nohup`, `perl` (with `POSIX::setsid`), `/usr/bin/shlock`, `ssh`/`ssh-keygen`/`ssh-copy-id`.

- **Detach.** A child spawned from the BEAM via `System.cmd("sh", ["-c", "<cmd> >log 2>&1 & echo $!"])`
  and then `System.halt`-ing the BEAM:
  | variant | survives BEAM halt | reparented (ppid=1) | stdio→log | `kill -HUP` immune | session leader |
  |---|---|---|---|---|---|
  | bare `&` | ✓ | ✓ | ✓ | ✗ (dies) | ✗ |
  | `nohup &` | ✓ | ✓ | ✓ | **✓** | ✗ |
  | `perl setsid &` | ✓ | ✓ | ✓ | ✗ (dies) | ✓ (Ss, pgid==pid) |
  | `nohup perl setsid &` | ✓ | ✓ | ✓ | ✓ | ✓ |
  Reparenting to launchd is what carries survival; `nohup` provides SIGHUP-immunity; `setsid` provides
  own-session. `echo $!` reliably captures the pid (the `nohup`/`perl` exec chain preserves it). A
  `SIGTERM` still stops the child — the basis for the `kill`→trap path. **Decision:** the engine spawns
  with **`nohup … & echo $!`** (survival + SIGHUP-immunity, no `perl` dependency); **own-session is
  pushed into the Swift sidecar's own `setsid()` at Plan 4** (cleanest home — the long-lived process
  owns its session). The `nohup perl -MPOSIX -e 'setsid; exec @ARGV'` shim is a proven fallback if we
  ever want own-session purely engine-side.

- **Host-wide lock.** A naive `O_EXCL`-create-then-write lock **failed** a mutual-exclusion test (8
  procs × 25 increments → **150**/200): the file exists but is *empty* between create and write, and a
  racer reading it empty wrongly "steals" it. The fix is an **atomic create-with-content** via
  `:file.make_link/2` (hard link fails with `:eexist` if the target exists, and the target already
  contains the holder record): the same test scored **200/200**, and stealing a **confirmed-dead**
  holder works. `shlock` exists and refuses a live holder correctly, but its stale-steal behavior was
  opaque in testing and it is pid-only (no start-time match). **Decision:** Elixir-native
  `:file.make_link/2` lock with `{pid, startedAt}` records and `Pidfile`-style start-time-matched
  liveness — zero external dep, unit-testable, defeats PID reuse.

- **Interactive ssh from an escript.** There is no `execve` in an escript, but
  `Port.open({:spawn_executable, …}, [:nouse_stdio, :exit_status, args: …])` leaves the child's fd
  0/1/2 inherited from the BEAM (Erlang talks over fd 3/4). Under a **real pty** the spawned child
  reports `CHILD-SEES-TTY` on `/dev/ttys006`, and the BEAM **still receives `:exit_status`**. So
  `vzbeam ssh <name>` can hand the real terminal to `ssh` for a fully interactive session and learn the
  exit code when it ends. (Confirmed the no-pty path too: child correctly sees no tty, exit_status
  delivered.)

- **`Port` streaming** (carried from the Plan 2 spike): `Port` (`{:line, N}` + `:exit_status`) streams
  output line-by-line live, where `System.cmd` buffers until exit — the basis for `restore` progress.

- **Toolchain present:** `ssh-keygen` (ed25519 keygen), `ssh`, `ssh-copy-id`, `caffeinate`. Erlang
  `File.open(path, [:write, :exclusive])` confirmed to give atomic `O_EXCL` (used only as a fallback;
  `make_link` is the chosen primitive).

---

## 3. `VzBeam.Lock` — host-wide advisory lock

`$VZBEAM_HOME/run.lock`. Serializes the `run` critical section across **separate `vzbeam` processes**
(not within one BEAM). Auto-recovers from a crashed holder.

```
@spec with_lock((-> result), timeout_ms :: pos_integer) :: {:ok, result} | {:error, :lock_timeout}
@spec acquire(timeout_ms) :: :ok | {:error, :lock_timeout}
@spec release() :: :ok
path() :: Path.t()              # $VZBEAM_HOME/run.lock
```

**`acquire/1`** loops until a deadline:
1. Build the holder record `Jason.encode!(%{"pid" => os_pid, "startedAt" => start})` where `os_pid =
   System.pid()` (the BEAM's OS pid) and `start = Pidfile.process_start(os_pid)` (reused, start-time
   match defeats PID reuse).
2. Write it to a unique temp `run.lock.<pid>.<unique>.tmp`, then `:file.make_link(tmp, path())`
   (**atomic**, content already present), and `File.rm(tmp)` either way.
3. `:ok` → acquired. `{:error, :eexist}` → read+decode the holder:
   - parseable **and** alive (`Pidfile.process_start(holder.pid) == holder.startedAt`) → sleep ~5 ms,
     retry until the deadline.
   - parseable **and** confirmed-dead → `File.rm(path())` (steal) and retry immediately.
   - unparseable/empty (should be impossible with `make_link` — corruption or a foreign writer) →
     treat as held; back off until the deadline, then `{:error, :lock_timeout}` (never silently steal
     an unreadable lock; the message is actionable: "remove `run.lock` if stale").

**`release/0`** is `File.rm(path())`. **`with_lock/2`** wraps acquire → run-fun → `release` in an
`after`, so a crash inside the critical section still releases (and even if the BEAM dies mid-section,
the next runner steals the dead-pid lock).

**Lock scope is deliberately narrow** (refines MVP §8, which lumps "spawn → vm.pid write"): the lock
covers **count-live-VMs → `Daemon.spawn_detached` → `Pidfile.write`** only (sub-second). The slow
startup handshake (§8) runs **outside** the lock. The just-spawned VM is countable immediately (its
`vm.pid` is written inside the lock), so a concurrent `run` cannot exceed the cap; meanwhile a 60 s boot
handshake never blocks a second `run`.

---

## 4. `VzBeam.Daemon` — detached spawn + pid capture

The one risky mechanism; isolated and unit-tested.

```
@spec spawn_detached(argv :: [String.t()], log_path :: Path.t(), runner \\ &System.cmd/3)
        :: {:ok, pid :: pos_integer} | {:error, term}
```

- Builds `"<nohup> #{shell_join(argv)} >#{q(log)} 2>&1 & echo $!"` and runs it via
  `runner.("sh", ["-c", cmd], [])` (default captured `System.cmd`). `nohup` is resolved to an absolute
  path; output redirection means `nohup` never creates a `nohup.out`.
- **Shell-quoting is load-bearing** (a place bugs hide): every argv token and the log path are wrapped
  in single quotes with internal `'` → `'\''`. Bundle names and `--share` host paths can contain
  spaces; an unquoted join would corrupt the command. A dedicated `q/1` helper + a spaces-in-path test.
- Parses `String.trim(out)` as the child pid (integer). The child is reparented to launchd on the
  immediate `sh` exit, so it survives the escript/BEAM exit; `nohup` makes it ignore SIGHUP; stdio is
  redirected to `log_path`.
- The caller (`Commands.Run`) is responsible for `Pidfile.write` and the handshake; `Daemon` only
  detaches and reports the pid.

**Why a shell and not a `Port`:** the spawn must *outlive* the BEAM and must not be a BEAM-owned port
(Plan 2 finding #5). `sh -c '… & echo $!'` is the portable, `setsid(1)`-free way to background +
reparent + capture the pid in one captured call.

---

## 5. `VzBeam.Sidecar` — `Port`-streamed `restore` (+ stderr tail)

Add a streaming sibling to `call/3` (which stays for `image-info`/`reid`/`--version`):

```
@spec stream(subcommand, args, on_event :: (event -> any), runner_or_opts)
        :: {:ok, [event], terminal :: event} | {:error, term}
```

- Opens a `Port` on `sh -c '#{q(path)} #{sub} #{args…} 2>#{q(stderr_tmp)}'` with
  `[:binary, :exit_status, {:line, @max_line}]`. **stderr → a temp file** (kept separate so it never
  corrupts the JSON-lines stdout — Plan 2 spike); stdout lines arrive as `{:line, data}`.
- Each complete line → `Protocol.decode_line/1`; `{:event, "progress", _}` is passed to `on_event`
  (live progress); events accumulate. On `{:exit_status, status}`, apply the same precedence as
  `call/3`: an `{"type":"error"}` event → `{:error, {:vz, …}}`; else `status != 0` → `{:error,
  {:exit, status, stderr_tail}}` (read the last ~4 KiB of `stderr_tmp`); else `Protocol.collect`-style
  terminal selection from the accumulated events. Removes `stderr_tmp` in an `after`.
- **`restore/2` switches from `call` to `stream`** (terminal `["restored"]`), logging `progress`
  fractions. This is transparent to `Commands.New`, which injects `restore` as a dep — the transport
  swap needs no `New` change. (Real progress is invisible against the instant fake and HW-gated for the
  real restore; Plan 3 validates the streaming *plumbing* + the stderr-tail-on-failure path.)

---

## 6. `VzBeam.Keys` — baked SSH keypair

```
@spec ensure(runner \\ &System.cmd/3) :: {:ok, %{private: Path.t(), public: Path.t()}} | {:error, term}
private() / public() :: Path.t()      # $VZBEAM_HOME/keys/id_ed25519[.pub]
```

- Lazy + idempotent: if `id_ed25519` is absent, `mkdir_p` `keys/` then `ssh-keygen -t ed25519 -N "" -C
  vzbeam -f <private>`; if present, no-op. Called by `run`, `stop`, and `ssh`.
- No setup verb (YAGNI). The keypair is host-wide and shared by every bundle (MVP §5). The public key
  is what the documented one-time `ssh-copy-id` installs into the base on first boot; it persists on
  disk and is inherited by clones (MVP §8).
- Green-bucket: `ssh-keygen` runs here; tests assert generation + idempotency in a tmp `$VZBEAM_HOME`.

---

## 7. `VzBeam.Share` — `--share` parse/validate

```
@spec parse(spec :: String.t()) :: {:ok, %{tag: String.t(), path: Path.t()}} | {:error, reason}
```

- Split on the **first** `=`. `tag` = left, `path` = right.
- Validate (MVP §9, tag rules already probed): `tag` non-empty, **≤ 36 bytes UTF-8** (`byte_size`),
  contains no `=`; `path` is expanded to absolute and the host directory must exist (`File.dir?`).
- Reasons: `:no_equals`, `:empty_tag`, `:tag_too_long`, `:no_such_dir`. Pure except the `File.dir?`
  check; trivially unit-tested. `Commands.Run` passes `["--share", tag, abs_path]` to `vz run`.

---

## 8. The `run` lifecycle

`Commands.Run.run(args, deps \\ default_deps())`, `deps = %{spawn: &Daemon.spawn_detached/2, sidecar:
…}` (the few injectable effects). Flow:

```
1. parse flags: --gui | --headless(default), --resolution WxH (Defaults), --share tag=/path
2. Manifest.read(name)  (else "no such bundle")
3. refuse if Pidfile.running?(name)  ("already running")
4. Share.parse if --share;  Keys.ensure();  vz = Sidecar.locate() then Sidecar.check_version(vz)
     (locate + version-check are read-only — done before the lock, fail fast on a missing/incompatible
     sidecar per MVP §10)
5. run_log = Path.join(Home.bundle_dir(name), "run.log");  build the run argv (argv[0] = located vz):
     [vz, "run", "--bundle", dir, "--mac", mac, "--cpu", n, "--mem", bytes,
      (--gui | --headless), "--resolution", WxH, ("--share", tag, abspath)?]
6. Lock.with_lock(fn ->                          # sub-second critical section
       running = Enum.count(Home.bundles(), &Pidfile.running?/1)
       if running >= 2 -> {:error, :at_capacity}          # UX pre-check
       else
         {:ok, pid} = deps.spawn.(argv, run_log)           # Daemon.spawn_detached
         :ok = Pidfile.write(name, pid)                    # countable immediately
         {:ok, pid}
       end
   end)
7. await_started(run_log_path, ~60_000 ms):                # OUTSIDE the lock
     read run.log → decode complete lines (drop a trailing partial)
       error event (incl. VZError 6) -> {:error, {:vz,…}}  # authoritative cap
       started{pid} -> {:ok, pid}                          # readiness gate
       process no longer alive & no started -> {:error, :exited_early}  (+ run.log tail)
       deadline passed -> {:error, :timeout}
       else sleep ~100 ms, repeat
8. on started: print  "started <name> (pid N) — networking; try `vzbeam ip <name>` / `vzbeam ssh <name>`"
              and, when keys/ was just created, the one-time `ssh-copy-id -i <pub> admin@<ip>` hint.
   on error/timeout/exited_early: kill -TERM the pid, File.rm vm.pid, return a typed error.
```

**`vm.pid` pid source.** The pid recorded is the spawned pid from `Daemon` (`echo $!`) — it is what
`kill` will signal and what `Pidfile.running?` checks. The `started` event's `pid` is the sidecar's
self-reported pid; with the `nohup` exec chain the two are identical. A mismatch (shouldn't happen) is
logged but the spawned pid stays authoritative for process control.

**2-VM cap (MVP §8, facts #1).** The in-lock count is the **UX pre-check**. The framework's `VZError
Code=6`, surfaced as an `error` event during the handshake, is **authoritative** and maps to the same
typed `:at_capacity` error (an external VZ user or stale state can trip it even when our pre-check
passed). `await_started` is where that path lands.

**Lifecycle states (MVP §8 Codex #11):** `starting → started → networking(bridge100) → ssh_ready`.
`run` returns at `started`; reachability (`networking`/`ssh_ready`) is derived later by `ip`/`ssh`/`stop`
from leases + an SSH poll — `bridge100` is the readiness tell (fact #8), so `stop`/`ssh` use bounded
polls and never conclude "broken" from a too-short wait.

`await_started` re-reads the whole (small) `run.log` each poll and only decodes newline-terminated
lines — the partial-final-line guard from `Protocol`. No offset tracking (YAGNI).

---

## 9. `stop` / `kill` / `ssh`

Shared helper `resolve_ip(name) :: {:ok, ip} | {:error, :no_lease}` =
`Leases.lookup_ip(Leases.read(), manifest["macAddress"])`. SSH option set (throwaway VMs whose IPs
recycle): `-i <Keys.private()> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o
LogLevel=ERROR -o ConnectTimeout=5`. `ssh_user` from `Defaults` (`admin`).

**`stop <name>`** (graceful — MVP §8, fact #4):
1. `Pidfile.running?` (else "not running"); `Keys.ensure`; `resolve_ip`.
2. `ssh … <user>@<ip> "sudo shutdown -h now"` (captured; a dropped connection on shutdown is success,
   not an error). **Requires passwordless `sudo` for the ssh user** — a one-time first-boot setup item
   documented alongside "create admin / enable Remote Login / ssh-copy-id" (HW-gated; surfaced in §12).
3. Poll `Pidfile.running?(name)` → false, bounded (~60 s; macOS shutdown is not instant). On stop:
   `File.rm` `vm.pid`. On timeout: report and suggest `vzbeam kill`.

**`kill <name>`** (force — MVP §8, fact #9, **never `pkill`**):
1. Read `vm.pid`; if not running, clean any stale `vm.pid` and report "not running".
2. `System.cmd("kill", ["-TERM", pid])` — the sidecar traps SIGTERM → `VZVirtualMachine.stop()` →
   emits `guest_stopped` → exits 0.
3. Poll for exit, bounded (~20 s). Still alive → `kill -KILL` (untrappable last resort), poll again.
4. `File.rm` `vm.pid`.

**`ssh <name> [-- cmd…]`** (interactive + one-shot):
1. `Keys.ensure`; `resolve_ip` (else actionable "no DHCP lease yet — is it networked? `vzbeam ip`").
2. `base = [opts…, "<user>@<ip>"]`.
   - **`-- cmd…`** (non-empty) → `System.cmd(ssh, base ++ cmd, stderr_to_stdout: false)`; return the
     captured stdout and **propagate the remote exit code** (`{:ok, out}` on 0, `{:error, code, out}`
     otherwise).
   - **bare** → interactive: `Port.open({:spawn_executable, ssh_abs}, [:nouse_stdio, :exit_status,
     args: base])`; block on `{:exit_status, s}`; return `{:ok, ""}` (s==0) or `{:error, s, ""}`. The
     session's I/O goes straight to the user's terminal (proven §2); vzbeam's own exit code is the
     ssh exit code.

`stop`/`kill`/`ssh` do **not** take `run.lock` — they act on an existing `vm.pid`, and only `run`
mutates the cap.

---

## 10. `fake_vz` extension (test seam)

Extend `test/support/fake_vz` (still a `/bin/sh` script) to model the run lifecycle for green-bucket
orchestration tests:

- `run …` → print `{"type":"started","pid":<getpid = $$>}` to stdout (which the engine has redirected
  to `run.log`), then **idle** (`while true; do sleep 1; done`) until signaled. A `trap` on `TERM`
  prints `{"type":"guest_stopped"}` and `exit 0` — modelling the sidecar's SIGTERM→`VZ.stop()` trap
  (drives `kill`, and `run`'s error/timeout cleanup).
- An error/cap mode (e.g. `VZBEAM_FAKE_RUN=error vz run …`, or a sentinel bundle name) → print
  `{"type":"error","domain":"VZErrorDomain","code":6,"message":"max VMs"}` and `exit` non-zero —
  drives the authoritative-cap path through `await_started`.
- A slow/never-started mode → idle without ever printing `started` — drives the handshake **timeout**.
- `restore …` (for the new `Sidecar.stream`) → print one or two `{"type":"progress","fraction":…}`
  lines then `{"type":"restored",…}` and `exit 0`; an error variant for the stderr-tail path.

The dummy long-running child + SIGTERM trap is exactly the daemonization shape proven in §2.

---

## 11. Reconciliations with the MVP spec

- **`setsid`/`flock` → substitutes (§2).** MVP §8's `setsid`/`flock` don't exist on macOS. Detach uses
  `nohup … & echo $!` (own-session deferred to the sidecar's `setsid()` at Plan 4); the lock uses
  `:file.make_link/2`. Same guarantees (survive escript exit, ignore SIGHUP, host-wide mutual
  exclusion), portable mechanisms.
- **Lock scope narrowed (§3, §8).** MVP §8 says the lock wraps "cap-check → spawn → vm.pid write"; this
  spec keeps the (slow) startup handshake **outside** the lock, because `vm.pid` is written inside it —
  the cap stays race-safe without holding a host-wide lock across a multi-second boot.
- **stderr tail (MVP §4) now honored.** Deferred from Plan 2; `run`'s stderr → `run.log` via the detach
  redirect, `restore`'s stderr → a temp file with the tail surfaced on failure (§5).
- **`run` returns at `started`, not `ssh_ready`** (MVP §8). Reachability is poll-derived later; matches
  the headless `RunLoop`/`bridge100` reality (facts #2, #8).

---

## 12. Error handling (per surface)

| Surface | Failure | Result |
|---|---|---|
| `run` | bundle missing / already running | refuse before any spawn |
| `run` | cap pre-check ≥ 2 (in lock) | typed `:at_capacity`, "stop a VM first" |
| `run` | `VZError 6` during handshake | same typed `:at_capacity` (authoritative); `vm.pid` cleaned |
| `run` | `error` event / early exit / timeout | `kill -TERM` the pid, remove `vm.pid`, typed error + `run.log` tail |
| `run` | `Lock` contention | `{:error, :lock_timeout}` → "another `vzbeam run` is in progress; retry" |
| `run` | `--share` invalid | refuse before spawn (`:no_equals`/`:empty_tag`/`:tag_too_long`/`:no_such_dir`) |
| `stop` | not running | "not running" (clean stale `vm.pid`) |
| `stop` | no lease / SSH unreachable | actionable ("no lease yet" / "enable Remote Login + install key") |
| `stop` | shutdown didn't complete in time | report + suggest `kill` |
| `kill` | not running | clean stale `vm.pid`, report |
| `kill` | SIGTERM ignored | escalate to `SIGKILL` (last resort); never `pkill` |
| `ssh` | no lease | actionable ("networking pending — `bridge100`/lease"; fact #8) |
| `ssh` | remote/ssh exit ≠ 0 | propagate the exit code |
| any | crashed lock holder | next `run` steals the confirmed-dead lock (§3) |

---

## 13. Testing strategy (green-bucket unless noted)

- **`Lock`** — mutual exclusion under N-way contention (counter == N×iters, the 200/200 spike as a
  test); stale-steal of a confirmed-dead pid; live-held → `:lock_timeout`; `with_lock` releases on a
  raising fun. Real filesystem (`make_link`).
- **`Daemon`** — spawn a real dummy child (`sleep`/tick): returns a live integer pid, writes the log,
  child is reparented (not a port of the test BEAM). Spaces-in-path quoting test. (Full "survives BEAM
  halt" is the standalone spike + the escript smoke-run — ExUnit's BEAM stays up.)
- **cap counting** — `Home.bundles ∩ Pidfile.running?` with fake live/stale `vm.pid`s → 0/1/2.
- **handshake** — feed `run.log` fixtures (started / error / none-yet / partial-final-line / dead-pid)
  → `{:ok,pid}` / `{:error,{:vz,…}}` / `:timeout` / `:exited_early`.
- **`Keys`** — generates ed25519, idempotent, in a tmp `$VZBEAM_HOME`.
- **`Share`** — good; `:no_equals`; oversize tag (37 bytes); missing dir; `=` in tag.
- **`Sidecar.stream`** — real `Port` against the extended `fake_vz` restore (progress → restored);
  `on_event` invoked; error variant → stderr-tail path.
- **`Commands.{Run,Stop,Kill,Ssh}`** — end-to-end via `CLI.run` against `fake_vz` + injected
  lease/ssh/lock: run → `started` → `vm.pid` written → cap refusal at 2 → timeout/error cleanup;
  stop → ssh-shutdown command shape + reap; kill → SIGTERM to the trapping fake → `vm.pid` cleaned;
  ssh → argv shape for `-- cmd` (injected runner) and the interactive path's exit-code propagation
  (mechanism proven by the §2 pty spike).
- **Escript smoke-run (the Plan-2 lesson):** build `./vzbeam` and actually run `run`/`stop`/`kill`/`ssh`
  against the fake in a scratch `$VZBEAM_HOME` — the real-syscall path that caught the Plan-2 mkdir bug
  the fakes masked.
- **HW-gated (documented, not run here):** real boot, AppKit window, live `VZError 6` cap, headless
  `RunLoop` networking, `bridge100`, real `stop`/`kill` of a guest, real `ssh` into a booted VM,
  passwordless-sudo shutdown.

---

## 14. Decided defaults & scope seams

- **Detach = `nohup … & echo $!`**; own-session deferred to the sidecar's `setsid()` (Plan 4).
- **Lock = `:file.make_link/2`** with `{pid, startedAt}` + start-time-matched liveness; steal only a
  confirmed-dead holder; `:lock_timeout` on a live/unreadable holder. Lock scope = count→spawn→`vm.pid`.
- **Handshake timeout ≈ 60 s**; timeout/error ⇒ kill the child + clean `vm.pid` + fail (an un-`started`
  VM isn't usable). Kill-reap ≈ 20 s before `SIGKILL`. Stop-reap ≈ 60 s.
- **SSH keys** lazy via `Keys.ensure/0`; **no setup verb**. SSH options assume throwaway VMs
  (`StrictHostKeyChecking=no`, `UserKnownHostsFile=/dev/null`).
- **Single `--share`** for the MVP; multiple shares deferred. `--gui` opt-in, `--headless` default.
- **`rm --force` deferred** (decided this session). **`caffeinate` deferred.**

---

## 15. Open questions

None blocking. Two items are explicitly HW-gated, not unknowns: (a) that a detached process reliably
shows the AppKit window and boots, and (b) the passwordless-sudo path for `stop`'s guest shutdown — both
validate on bare-metal Apple Silicon at the Plan-4 build milestone. A Codex pass on this spec (and
especially on the riskiest mechanisms — `Daemon` detach + `Lock` atomicity) should run before the
implementation hardens, per the project's review convention.
