# OpenBSD ISO Support Design

**Date:** 2026-09-21
**Status:** Approved in conversation; awaiting written-spec review
**Branch:** `openbsd-iso-support`

## 1. Goal

Add interactive installation and lifecycle support for OpenBSD 7.9 or newer on Apple Silicon through Apple's Virtualization framework. A user supplies a local ARM64 OpenBSD ISO, completes the normal graphical installer, and then manages the installed bundle with the existing vzbeam lifecycle where the guest supports it.

The first delivery optimizes for a reliable OpenBSD path, not a universal ISO-guest framework. Its boundaries must nevertheless allow a later Linux guest to reuse the generic EFI platform, ISO cache, and installation flow without restructuring the application.

## 2. Success criteria

The feature is successful when a user can:

1. Create an OpenBSD bundle with `vzbeam new NAME --iso PATH`.
2. Complete the interactive OpenBSD installer in a host GUI and finish with `halt -p`.
3. Boot the installed system normally without its ISO, either GUI or headless.
4. Boot the bundle with its cached installer ISO using `vzbeam run NAME --iso`.
5. Boot once with alternate local media using `vzbeam run NAME --iso PATH` without changing the bundle's cached media.
6. Use `ip`, `ssh`, `stop`, `kill`, `clone`, `set`, and `rm` wherever hardware validation shows the existing lifecycle is applicable.
7. Continue using existing macOS bundles and commands without behavioral regressions.

Lifecycle parity is progressive. Installation, normal boot, and ISO recovery are the first shippable slice; commands that expose guest-specific problems may be deferred individually and documented rather than blocking that slice.

## 3. Scope

### In scope

- OpenBSD 7.9+ ARM64 installation from a local ISO.
- A generic EFI Virtualization-framework configuration for OpenBSD.
- Persistent generic machine identity, MAC address, writable disk, and EFI variables.
- VirtIO disk, networking, graphics, and entropy devices.
- USB keyboard and absolute-coordinate pointing input for GUI sessions.
- Content-addressed retention of local ISO media.
- Cached and one-shot recovery boots.
- Guest-aware manifests, cloning, SSH user, graceful shutdown, disk guidance, sharing policy, and macOS concurrency policy.
- Elixir, Swift, protocol, CLI, documentation, and bare-metal validation changes.

### Out of scope

- Unattended OpenBSD installation or `autoinstall(8)` orchestration.
- ISO downloads over HTTP or HTTPS.
- Automatic verification against OpenBSD's signed SHA256 manifests.
- General Linux support in this change.
- VirtioFS for OpenBSD.
- Live installer-media ejection.
- Automatic inspection of arbitrary ISO contents or architecture.
- ISO cache listing, pruning, or garbage collection.
- A general guest-plugin framework.

## 4. Domain model

The design separates four concepts that were previously all implicit in the macOS-only path:

- **Guest OS** identifies guest behavior: `macos`, `openbsd`, and later `linux`.
- **Platform** identifies virtual hardware and boot: Mac platform or generic EFI platform.
- **Install media** identifies acquisition and installation: IPSW restore or ISO boot.
- **Capabilities** identify guest policy: shutdown command, directory sharing, SSH defaults, and concurrency limits.

Guest OS determines platform and capabilities. Platform and computed capabilities are not duplicated in the manifest.

The first implementation uses a small guest-policy module and two Swift configuration builders. It does not introduce plugin discovery or a general driver interface.

## 5. CLI

Existing macOS forms remain unchanged:

```text
vzbeam new NAME --image <latest|PATH|URL|BUILD>
vzbeam new NAME BASE
vzbeam run NAME [--gui|--headless] [--resolution WxH] [--share TAG=PATH]
```

OpenBSD adds:

```text
vzbeam new NAME --iso PATH [--cpu N] [--mem-gb M] [--disk-gb G]
                              [--ssh-user USER] [--resolution WxH]

vzbeam run NAME --iso
vzbeam run NAME --iso PATH
```

For `new`, `--iso PATH` means an OpenBSD 7.9+ ARM64 installation. It accepts only a local regular file in the first release. The selected SSH user defaults to `admin` and must match the non-root user created in the OpenBSD installer.

For `run`:

- Bare `--iso` attaches the bundle's cached install media.
- `--iso PATH` attaches the specified local ISO for this invocation only.
- Both forms attach media read-only, place it before the installed disk in boot order, imply GUI mode, and conflict with `--headless`.
- A one-shot override remains attached across guest reboots within that run. It is discarded when the VM process exits and never changes the manifest or cached ISO.

The two `run --iso` forms require a small command-specific parser because Elixir's `OptionParser` does not represent an option with an optional value. The grammar is unambiguous because `run` has exactly one required positional bundle name.

## 6. Manifest and bundle layout

Manifest schema version increases from 1 to 2. A schema-1 manifest without `guestOS` normalizes to `macos` in memory. The file is upgraded when a later command writes it. Unknown keys remain preserved, and schema versions newer than the program supports are rejected explicitly.

An OpenBSD base manifest has this shape:

```json
{
  "schemaVersion": 2,
  "guestOS": "openbsd",
  "name": "openbsd",
  "base": null,
  "image": {
    "kind": "iso",
    "source": "/absolute/original/path/install79.iso",
    "file": "<sha256>.iso",
    "sha256": "<hex digest>",
    "version": "7.9"
  },
  "machineIdentifier": "<base64 generic machine identifier>",
  "macAddress": "5e:aa:bb:cc:dd:ee",
  "sshUser": "admin",
  "cpuCount": 4,
  "memoryBytes": 8589934592,
  "createdAt": "2026-09-21T00:00:00Z"
}
```

`version` is inferred only from recognized official basenames such as `install79.iso` and `cd79.iso`. Other non-empty local ISO files remain valid and store no inferred version.

OpenBSD bundle files are:

```text
<name>/
  config.json
  disk.img
  nvram.bin
  vm.pid          # while running
  run.log
```

macOS bundles retain `disk.img` and `aux.img`. The macOS-only `hardwareModel` field is absent from OpenBSD manifests.

Installation state is not persisted in a completed bundle. Work in progress lives in `<name>.pending`, which normal bundle discovery ignores.

## 7. ISO retention

Local OpenBSD media is retained under:

```text
$VZBEAM_HOME/cache/iso/<sha256>.iso
```

Acquisition streams the source through SHA-256, rejects empty files, and promotes a temporary file atomically. Placement uses the repository's existing copy-on-write copy strategy where the filesystem supports it. A digest hit reuses the existing file.

The cached ISO is shared by any number of bundles. Clones inherit only its manifest reference. Removing a bundle does not remove cached media. Cache garbage collection is deferred.

The digest provides identity and corruption detection against the recorded value; it does not prove authenticity. Users remain responsible for verifying OpenBSD release signatures before creation.

At normal boot no ISO is attached. Bare `run --iso` resolves the manifest's cached file and fails clearly if it is missing. `run --iso PATH` validates and attaches the provided file directly without caching it.

## 8. Swift architecture

Swift gains a `GuestOS` discriminator and two configuration builders:

- The Mac builder preserves the current `VZMacPlatformConfiguration`, `VZMacOSBootLoader`, Mac graphics, auxiliary storage, and IPSW behavior.
- The generic EFI builder serves OpenBSD and is reusable by a later Linux guest.

The OpenBSD configuration contains:

- `VZGenericPlatformConfiguration` with a persisted `VZGenericMachineIdentifier`.
- `VZEFIBootLoader` with a persisted `VZEFIVariableStore` at `nvram.bin`.
- A writable `VZVirtioBlockDeviceConfiguration` for `disk.img`.
- `VZVirtioNetworkDeviceConfiguration` with NAT and the persisted MAC.
- `VZVirtioGraphicsDeviceConfiguration` with one scanout at the requested resolution.
- `VZVirtioEntropyDeviceConfiguration`.
- USB keyboard and screen-coordinate pointing devices for GUI sessions.
- When requested, a read-only `VZUSBMassStorageDeviceConfiguration` for the ISO, ordered before the writable disk.

Graphics remain present in headless OpenBSD configurations so the guest sees stable virtual hardware; headless mode omits only the host window and interactive input devices.

Audio, memory ballooning, serial-console UX, clipboard integration, and directory sharing are deferred.

## 9. Interactive installation flow

`vzbeam new NAME --iso PATH` performs this sequence:

1. Validate name, sizing, SSH user, resolution, source file, and destination absence.
2. Retain the ISO in the content-addressed cache.
3. Clear a stale `<name>.pending`, create it, and create the sparse `disk.img`.
4. Invoke the sidecar's guest-aware `install` command as a foreground streamed process.
5. Swift creates `nvram.bin`, mints the generic machine identifier and MAC, validates the configuration, starts the VM, and opens the AppKit window.
6. Elixir remains attached until a terminal sidecar event.
7. A normal guest power-off emits `installed` with the opaque identity fields.
8. Elixir writes the schema-2 manifest and atomically renames the pending directory to `<name>`.

Before opening the window, the CLI tells the user to:

- Create the configured SSH user, default `admin`.
- Leave `sshd` enabled.
- Finish installation with `halt -p`, not reboot.

The framework exposes no OpenBSD installer-completion signal. Therefore success means the VM started and later powered off normally. Reboot keeps the ISO attached and does not finish the command; the user must eventually power off.

Closing the installer window is cancellation. Swift stops the VM, emits an error terminal, and exits nonzero. Controlled errors remove the pending bundle. A host crash, power loss, or `SIGKILL` can leave a stale pending directory; it stays invisible and is cleared by the next creation attempt.

## 10. Sidecar protocol

The protocol version increases from 1 to 2 so an old sidecar cannot be used accidentally with guest-aware manifests or arguments.

New installation events are:

```json
{"type":"install_started","pid":4321}
{"type":"installed","machineIdentifier":"<base64>","macAddress":"5e:aa:bb:cc:dd:ee"}
```

The existing structured error event remains authoritative. `installed` is emitted only after `guestDidStop` following a successful VM start. `didStopWithError`, configuration failure, media failure, or cancellation emits an error and exits nonzero.

Sidecar commands become guest-aware:

```text
vz install --guest openbsd --iso ... --disk ... --nvram ... --cpu ... --mem ... --resolution ...
vz run --guest openbsd --machine-id ... --mac ... --disk ... --nvram ... [--iso ...] ...
vz reid --guest <macos|openbsd>
```

The current `restore`, `image-info`, signal-driven force-stop behavior, and JSON-lines robustness rules remain intact.

The foreground installation transport must not orphan the AppKit sidecar if the BEAM exits. Normal close, SIGINT, and SIGTERM paths stop the VM and reap the child. Unpreventable hard termination is handled by stale-pending cleanup.

## 11. Elixir guest policy

A small guest-policy module centralizes behavior that would otherwise become scattered conditionals. It defines:

- Manifest normalization and supported guest values.
- Platform identity kind for `reid`.
- Whether directory sharing is available.
- Default and stored SSH user.
- Graceful-shutdown argv.
- Whether the guest consumes a macOS concurrency slot.
- Guest-specific disk-growth guidance.

It is a closed internal mapping, not plugin discovery.

Policies for the initial guests are:

| Capability | macOS | OpenBSD |
|---|---|---|
| Platform | Mac | Generic EFI |
| Install media | IPSW | ARM64 ISO |
| Default SSH user | `admin` | `admin` |
| Graceful shutdown | `sudo -n shutdown -h now` | `doas -n /sbin/shutdown -p now` |
| VirtioFS share | yes | no |
| Two-VM preflight slot | yes | no |

A future Linux policy can reuse generic EFI installation while supplying Linux shutdown, sharing, and optional guest-integration behavior.

## 12. Lifecycle behavior

### Run and recovery

Normal `run` selects its Swift configuration from `guestOS`. OpenBSD passes no ISO unless the user supplies `--iso`.

Bare `run --iso` attaches cached media. `run --iso PATH` attaches one-shot media. Both imply GUI and reject `--headless`. Recovery shutdown leaves the manifest unchanged.

### Networking and SSH

OpenBSD uses the existing NAT attachment and host DHCP-lease lookup by MAC. `SshConn` accepts the manifest's `sshUser` rather than always using the global default. Key creation and `ssh-copy-id` remain a documented one-time setup after installation.

### Graceful and forced stop

`stop` selects a command from guest policy. OpenBSD runs:

```text
doas -n /sbin/shutdown -p now
```

The user configures a narrow `nopass` rule in `/etc/doas.conf`; failure returns an actionable message and points to `kill`. Signal-driven `kill` remains guest-independent.

### Clone

A stopped OpenBSD bundle is copied as a unit, including disk and EFI variables. `reid --guest openbsd` replaces the generic machine identifier and MAC while preserving the cached-media reference and SSH user. The ISO bytes are not duplicated.

### Set and list

CPU, memory, and sparse-disk resizing remain shared. macOS keeps its recovery-partition warning. OpenBSD receives guidance that host-side growth creates unallocated guest space which must be incorporated using OpenBSD disk and filesystem tools.

`ls` renders `OpenBSD` plus an inferred version when present. IP, sizing, status, and base columns remain unchanged.

### Sharing and VM limits

`run --share` on an OpenBSD bundle fails before spawn with an explicit unsupported-guest message. OpenBSD's documented VirtIO device set does not include VirtioFS.

The lock around VM launch remains. The preflight count of two applies only when launching macOS and counts only running macOS bundles. OpenBSD is not assigned an artificial two-VM limit; framework errors remain authoritative.

## 13. Error handling

- Invalid CLI combinations fail before filesystem or sidecar mutation.
- `new --iso` rejects missing, non-regular, or empty media.
- Bare `run --iso` reports a missing cached file with the recorded digest and remediation.
- One-shot ISO validation failures name the supplied path.
- Sidecar errors preserve their domain, code, message, and stderr tail.
- A guest stop before the VM reports successful start is an installation failure.
- An ordinary power-off after successful start is installation completion because no deeper installer signal exists.
- `run --iso` and `--headless` are mutually exclusive.
- `run --share` is rejected for OpenBSD before spawning the sidecar.
- Unsupported manifest schema versions and guest values fail explicitly.
- Existing macOS error mappings remain unchanged.

## 14. Testing strategy

### Elixir validation

The normal `mix test` suite covers:

- Schema-1 macOS normalization and schema-2 round trips.
- Guest-policy values and unsupported guests.
- ISO hashing, atomic placement, deduplication, empty files, stale files, and copy failures.
- Official-name version inference and custom filenames.
- `new --iso` parsing, mutual exclusions, progress/instruction output, success, cancellation, error cleanup, and stale pending cleanup.
- Both `run --iso` forms, GUI implication, headless conflict, cached-media lookup, one-shot behavior, and argv construction.
- Protocol-v2 negotiation and `install_started`/`installed`/error precedence through the fake sidecar.
- Per-bundle SSH users and OpenBSD shutdown arguments.
- Guest-aware cloning, listing, resizing messages, sharing rejection, and macOS-only cap counting.
- Regression coverage for all existing macOS command forms.

### Swift validation

Swift tests or the existing validation executable cover:

- Generic machine-identifier serialization.
- Guest argument parsing and rejection.
- EFI variable-store creation.
- OpenBSD install, normal-run, cached-recovery, and one-shot-recovery configuration validation with temporary files.
- ISO read-only attachment and storage ordering.
- VirtIO device selection, GUI inputs, and headless configuration.
- Protocol-v2 event encoding.

These checks do not require starting a VM and can run on the virtualized development host.

### Bare-metal Apple Silicon validation

The hardware-gated suite uses the official OpenBSD 7.9 ARM64 `install79.iso` and verifies:

1. Interactive installation, user creation, `sshd`, and `halt -p` completion.
2. Normal GUI and headless boots without attached media.
3. DHCP lease discovery and SSH after key installation.
4. Narrow `doas` configuration and graceful `stop`.
5. Signal-driven `kill`.
6. Bare cached-ISO recovery and one-shot alternate-ISO recovery.
7. Visibility of the installed disk from recovery media.
8. Clone boot with distinct generic identity and MAC.
9. Guest-aware `set`, `ls`, and `rm` behavior.
10. Continued macOS restore and run behavior on representative existing bundles.

## 15. Delivery sequence

### Phase 1: installation and recovery

- Manifest normalization and guest policy.
- Content-addressed ISO cache.
- Protocol v2 and generic EFI Swift configuration.
- Interactive `new --iso`.
- Normal OpenBSD `run`.
- Cached and one-shot `run --iso`.

### Phase 2: lifecycle parity

- IP and per-bundle SSH user.
- OpenBSD graceful stop.
- Clone and generic re-identification.
- Guest-aware `set`, `ls`, sharing rejection, and macOS cap behavior.

### Phase 3: documentation and hardware closure

- README and command help.
- SSH key and `doas.conf` setup instructions.
- Recovery workflow and limitations.
- Physical Apple Silicon acceptance results.
- Explicit deferral notes for any lifecycle item that hardware exposes as unreliable.

Each phase keeps the test suite green. Hardware-dependent failures may defer an individual parity feature, but they do not weaken the installation and recovery acceptance criteria.

## 16. Documentation updates

The README and CLI help will state:

- OpenBSD 7.9+ and Apple Silicon ARM64 media are required.
- `new --iso` is interactive and must end with `halt -p`.
- The installer ISO is retained for recovery.
- The difference between cached and one-shot `run --iso`.
- The configured installer username must match `sshUser`.
- The one-time `ssh-copy-id` and narrow `/etc/doas.conf` rule.
- OpenBSD does not support vzbeam's VirtioFS `--share` path.
- ISO authenticity is not verified automatically.
- Installation and boot require physical Apple Silicon because nested Virtualization-framework guests are unavailable on the development VM.

## 17. Settled decisions

- OpenBSD installation is interactive only.
- `new --iso` launches installation immediately and blocks until guest power-off.
- The first release accepts local media only.
- Bare `--iso` means OpenBSD for `new`.
- Controlled installation failure discards the incomplete bundle.
- Guest lifecycle parity is pursued pragmatically and may be phased.
- The shared-core, guest-aware architecture is preferred over duplicate paths or a plugin framework.
- Existing schema-1 bundles remain implicit macOS bundles.
- Install media is retained for recovery in a shared content-addressed cache.
- `run --iso` uses cached media; `run --iso PATH` is a one-run override.
- ISO recovery implies GUI and conflicts with headless mode.
- Linux can later reuse generic EFI and ISO machinery through a new guest policy.

## 18. Open questions

None. The design is ready for an implementation plan after written-spec review.
