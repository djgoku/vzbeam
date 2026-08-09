# Growing an existing VM's root volume (experimental, host-side)

`set --disk-gb` and a clone's `--disk-gb` grow the raw disk, but the guest's
root volume cannot expand into that space: macOS lays the recoveryOS
partition directly behind the root container, and `diskutil` refuses to
remove an "APFS Recovery Physical Store" from the booted guest *and* from
the host (the refusal is role-based, not just SIP).

The escape hatch — validated end-to-end on a macOS 26.6.1 guest — is to
drop the recovery partition's GPT entry by editing `disk.img` directly
(below `diskutil`'s policy layer), then let APFS grow into the
now-contiguous free space. Everything runs on the host with the VM
stopped; no guest interaction is needed.

## Trade-offs — read first

- **recoveryOS is deleted.** The VM can no longer boot into recovery, and
  macOS software updates inside the guest may fail without it (the same
  trade Tart's `recovery_partition: "delete"` makes). Best suited to
  disposable clones; for a full-size root on a keeper VM, prefer sizing at
  restore time: `vzbeam new <name> --image <spec> --disk-gb G`.
- The `diskutil` steps require `sudo`.
- Editing the image while it is attached or the VM is running will corrupt
  it. Stop the VM first; work on a clone if unsure.

## Procedure

The VM must be stopped. `$B` is the bundle, e.g.
`B=$VZBEAM_HOME/<name>`.

1. Grow the image if you haven't already (`vzbeam set <name> --disk-gb G`).

2. Inspect the GPT and identify the recovery entry (read-only):

   ```sh
   python3 scripts/gptedit.py list "$B/disk.img"
   ```

   Expect three entries; recovery is the ~5.4 GB `RecoveryOSContainer`,
   flagged `[recoveryOS]` in the listing.

3. Remove it (zeroes the entry in the primary and backup GPT, rewrites CRCs):

   ```sh
   python3 scripts/gptedit.py remove-recovery "$B/disk.img"
   ```

   `remove-recovery` locates the partition by its type GUID, so there is no
   index to get wrong. The script also refuses device nodes (regular files
   only), refuses images that are currently `hdiutil`-attached, and its
   `remove <n>` form refuses non-recovery partitions unless `--force` is
   given.

4. Attach the image and grow the container into the freed space
   (substitute the `diskN` printed by `attach`):

   ```sh
   hdiutil attach -nomount "$B/disk.img"
   sudo diskutil repairDisk diskN
   sudo diskutil apfs resizeContainer diskNs2 0
   hdiutil detach diskN
   ```

   `resizeContainer` runs a full `fsck_apfs` first; expect
   "The container ... appears to be OK" before the grow.

5. Boot and verify:

   ```sh
   vzbeam run <name> --headless
   vzbeam ssh <name> -- df -h /
   ```

   The root volume now spans the full disk.

## Future work

- Automate this inside `vzbeam set --disk-gb` behind an explicit opt-in
  flag (e.g. `--delete-recovery`), with the GPT editing ported to an
  Elixir module (binary pattern matching + `:erlang.crc32`; no external
  tools beyond `hdiutil`/`diskutil`).
- A "relocate" variant (move recovery to the end of the disk, Tart-style)
  would keep recoveryOS and software updates working at the cost of
  copying ~5.4 GB during the resize.
