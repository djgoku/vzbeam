# vzbeam

vzbeam manages disposable virtual-machine bundles on Apple Silicon using Apple's Virtualization framework. This glossary keeps guest, media, and lifecycle language consistent as support expands beyond macOS.

## Language

**Bundle**:
A self-contained virtual machine's persistent disk, platform identity, configuration, and runtime metadata.
_Avoid_: VM directory, machine folder

**Guest OS**:
The operating-system family installed in a bundle, such as macOS or OpenBSD.
_Avoid_: Image type, platform

**Platform**:
The virtual hardware and boot environment presented to a guest: Mac platform for macOS or generic EFI platform for OpenBSD and future ISO guests.
_Avoid_: Guest OS, architecture

**Install media**:
The external source used to create a bundle, such as a macOS IPSW or an OpenBSD ISO.
_Avoid_: Boot disk, guest disk

**Recovery boot**:
A run that temporarily attaches cached or one-shot install media ahead of the installed guest disk.
_Avoid_: Reinstall, recovery image

**Base**:
A fully installed bundle used as the source of a copy-on-write clone.
_Avoid_: Template, image

**Clone**:
An independent copy-on-write bundle derived from a stopped base and assigned a fresh platform identity and MAC address.
_Avoid_: Snapshot, linked VM
