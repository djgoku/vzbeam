# OpenBSD ISO support: physical Apple Silicon results

Date: 2026-09-22

Branch: `openbsd-iso-support`

Host: MacBook Neo (`Mac17,5`), Apple A18 Pro, 8 GB RAM

Host OS: macOS 27.2 (`26B5091g`), `arm64`

This record separates physical VM observations from non-booting configuration checks.
`PASS`, `FAIL`, and `DEFERRED` describe only work actually performed on this host.

## Host and media preconditions

- **PASS** — `uname -m` returned `arm64`.
- **PASS** — `sw_vers` returned macOS 27.2, build `26B5091g`.
- **PASS** — `mix vz.build` produced and installed the signed sidecar at
  `~/.local/share/vzbeam/bin/vz`.
- **PASS** — the OpenBSD 7.9 ARM64 release signature was verified with the
  OpenBSD 7.9 base public key, and the local files matched the signed release
  manifest from the [official ARM64 release directory](https://cdn.openbsd.org/pub/OpenBSD/7.9/arm64/):

  ```text
  49786ab82868b6e508a0117c0c1567694a2f6b46caf8972c726868617b8c22fb  install79.iso
  33586d1c4030875767823aab785e2fae5ab1d93370368a1b223689798b808fa4  cd79.iso
  ```

## Interactive installation

Command:

```sh
./vzbeam new openbsd \
  --iso /private/tmp/vzbeam-openbsd79-arm64/install79.iso \
  --ssh-user admin
```

- **PASS** — the OpenBSD 7.9 ARM64 installer booted in the Virtualization.framework
  window and completed an interactive installation.
- **PASS** — `halt -p` ended the install process and promoted the pending bundle.
- **PASS** — the final bundle contained `config.json`, `disk.img`, and `nvram.bin`,
  with no pending bundle left behind.
- **PASS** — the schema-2 manifest recorded `guestOS: openbsd`, the `admin` SSH user,
  a generic machine identifier and MAC, and the cached ISO digest above.

## Normal boot and lifecycle

- **PASS** — GUI boot reached the installed login prompt.
- **PASS** — headless boot reached SSH at `192.168.64.3`.
- **PASS** — `./vzbeam ssh openbsd -- uname -a` returned:

  ```text
  OpenBSD foo.localdomain 7.9 GENERIC.MP#222 arm64
  ```

- **PASS** — before guest policy was configured, `vzbeam stop` reported the guest-side
  privilege denial rather than claiming success.
- **PASS** — after adding only this guest rule, `vzbeam stop openbsd` powered off cleanly:

  ```text
  permit nopass admin as root cmd /sbin/shutdown args -p now
  ```

- **PASS** — a later headless boot followed by `vzbeam kill openbsd` force-stopped the VM.
- **PASS** — `vzbeam ip`, `vzbeam ls`, GUI mode, and headless mode all reported the
  OpenBSD bundle consistently.

## OpenBSD graphical desktop

- **PASS** — `xenodm` was present in the installed system.
- **PASS** — after `rcctl enable xenodm` and `rcctl start xenodm`, the VM displayed the
  graphical login, `cwm`, `xterm`, and `xconsole`.
- **PASS** — keyboard, pointing, VirtIO graphics, and `vio0` networking were usable from
  the graphical session.
- **PASS** — `halt -p` from the root xterm powered off the VM cleanly.

## Cached and one-shot recovery

Final commands:

```sh
./vzbeam run openbsd --iso
./vzbeam run openbsd --iso /private/tmp/vzbeam-openbsd79-arm64/cd79.iso
```

Observed EFI-selection failures were retained as evidence rather than hidden:

- **FAIL, fixed** — boot-time ISO-first ordering with the installed disk on VirtIO
  allowed the installed system to boot instead of one-shot `cd79.iso`.
- **FAIL, fixed** — a fresh invocation-only EFI variable store did not change that
  selection.
- **FAIL, fixed** — placing both devices on USB made `cd79.iso` boot, but cached
  `install79.iso` later lost EFI selection to the installed disk on a cloned bundle.
- **PASS, final design** — recovery now starts with only the read-only ISO and a fresh
  temporary EFI variable store, then hot-plugs the writable installed disk through an
  explicit XHCI controller before reporting `started`. This deterministic path requires
  macOS 15 or newer; installation and normal boot keep the macOS 13 floor.

Final physical results:

- **PASS** — cached `install79.iso` booted the installer, hot-plugged the installed disk
  as `sd1`, retained the installer across a guest `reboot`, and ended on `halt -p`.
- **PASS** — one-shot `cd79.iso` booted the installer, hot-plugged the installed disk as
  `sd1`, and ended on `halt -p`.
- **PASS** — the installer ramdisk exposed the hot-plugged disk after:

  ```sh
  cd /dev
  sh MAKEDEV sd1
  disklabel sd1
  ```

- **PASS** — recovery temporary directories were removed after both invocations.
- **PASS** — the final cached and one-shot runs left these bundle hashes unchanged:

  ```text
  bd7d785d885d1e9a29cd43230bfd67a512167e6ed95bce14f01fb5badfcc2ebb  config.json
  402786b227a8410259451e4e0c45d8d41d20c382c36001891fa3eb612dbbbfc9  nvram.bin
  ```

- **PASS** — the ISO cache still contained only the install-media digest; one-shot
  `cd79.iso` was not cached.
- **PASS** — a following normal boot returned the installed OpenBSD kernel over SSH,
  proving recovery media detached.

## Clone, disk growth, and removal

Commands:

```sh
./vzbeam new openbsd-copy openbsd
./vzbeam set openbsd-copy --disk-gb 65
./vzbeam run openbsd-copy --gui
./vzbeam rm openbsd-copy
```

- **PASS** — the stopped clone received a different generic machine identifier and MAC
  while inheriting the OpenBSD guest type, SSH user, disk contents, EFI variables, and
  cached-media metadata.
- **PASS** — the clone received its own DHCP lease and booted both the graphical desktop
  and SSH.
- **PASS** — host-side growth changed the sparse image from 64 GiB to 65 GiB.
- **PASS** — guest `disklabel sd0` reported exactly `136314880` sectors while the
  existing OpenBSD boundary initially remained at `134217728`, demonstrating 1 GiB of
  new unallocated capacity.
- **PASS** — on the disposable clone, recovery extended MBR entry 3 from `133652480` to
  `135749632` sectors without moving its `565248` start, extended the disklabel boundary
  to `136314880`, and extended `/home` partition `l` from `38577664` to `40674816`
  sectors.
- **PASS** — `growfs -N sd1l`, `growfs sd1l`, and `fsck -fy /dev/rsd1l` completed from
  recovery with `/home` unmounted.
- **PASS** — after normal boot, `df -h /home` reported:

  ```text
  /dev/sd0l  18.8G  20.0K  17.8G  1%  /home
  ```

- **PASS** — the clone was stopped and removed; the original 64 GiB OpenBSD bundle and
  cached installer remained intact.

## Automated checks

- **PASS** — `mix test`: 285 tests passed.
- **PASS** — the ad-hoc-signed `vzcheck` executable reported `ALL CHECKS PASS`, including
  temporary NVRAM cleanup, ISO-only recovery storage, explicit XHCI configuration,
  installation storage, normal storage, graphics, input, network, and parser checks.

## Deferred parity checks

- **DEFERRED** — physical macOS restore, run, and VirtioFS share regression. No macOS
  bundle was present on this host, and a new restore is a separate long-running hardware
  operation rather than an OpenBSD acceptance blocker.
- **DEFERRED** — physically running two macOS guests and rejecting a third while an
  OpenBSD guest is present. The guest-slot policy remains covered by the automated suite,
  but the three-VM hardware setup was not executed.

No installation, normal-boot, cached-recovery, one-shot-recovery, clone, graphical, or
disk-growth acceptance item remains deferred.
