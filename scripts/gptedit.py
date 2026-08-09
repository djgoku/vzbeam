#!/usr/bin/env python3
"""List or remove a GPT partition entry in a raw disk image (e.g. a VZ disk.img).

Usage:
  gptedit.py list <disk.img>
  gptedit.py remove-recovery <disk.img>             # remove the recoveryOS partition
  gptedit.py remove <disk.img> <partition-number>   # 1-based; refuses non-recovery
                                                    # entries unless --force is given

Removing zeroes the partition's entry in BOTH the primary and backup GPT
entry arrays and rewrites the entries-CRC and header-CRC in both headers.
The partition's data blocks are left in place (orphaned), which is exactly
what "delete the recovery partition" means for our purposes.

Safety guards:
  - operates only on regular files, never on /dev nodes
  - refuses to edit an image that is currently attached (hdiutil)
  - `remove` only deletes the Apple recoveryOS partition type unless --force
"""
import os, plistlib, stat, struct, subprocess, sys, uuid, zlib
from xml.parsers.expat import ExpatError

SECTOR = 512
RECOVERY_TYPE = "52637672-7900-11AA-AA11-00306543ECAC"  # Apple_APFS_Recovery

def read_header(f, lba):
    f.seek(lba * SECTOR)
    raw = f.read(92)
    sig, rev, hsize, hcrc, _res, cur, backup, first, last, guid, elba, ecount, esize, ecrc = \
        struct.unpack("<8sIIII QQQQ 16s QIII", raw)
    if sig != b"EFI PART":
        raise SystemExit(f"no GPT header at LBA {lba} (signature {sig!r})")
    # verify header CRC
    zeroed = raw[:16] + b"\x00\x00\x00\x00" + raw[20:hsize]
    if zlib.crc32(zeroed) & 0xFFFFFFFF != hcrc:
        raise SystemExit(f"header CRC mismatch at LBA {lba}")
    return dict(raw=raw, hsize=hsize, cur=cur, backup=backup, first=first, last=last,
                elba=elba, ecount=ecount, esize=esize, ecrc=ecrc, lba=lba)

def read_entries(f, hdr):
    f.seek(hdr["elba"] * SECTOR)
    data = bytearray(f.read(hdr["ecount"] * hdr["esize"]))
    if zlib.crc32(data) & 0xFFFFFFFF != hdr["ecrc"]:
        raise SystemExit(f"entries CRC mismatch for header at LBA {hdr['lba']}")
    return data

def parse_entry(data, i, esize):
    off = i * esize
    type_guid = bytes(data[off:off+16])
    if type_guid == b"\x00" * 16:
        return None
    part_guid = bytes(data[off+16:off+32])
    first, last = struct.unpack_from("<QQ", data, off+32)
    name = data[off+56:off+128].decode("utf-16-le").rstrip("\x00")
    return dict(i=i, type=str(uuid.UUID(bytes_le=type_guid)).upper(),
                first=first, last=last, name=name,
                guid=str(uuid.UUID(bytes_le=part_guid)).upper())

def show(f):
    hdr = read_header(f, 1)
    data = read_entries(f, hdr)
    print(f"disk: first usable LBA {hdr['first']}, last usable LBA {hdr['last']} "
          f"({(hdr['last']+1)*SECTOR/1e9:.1f} GB)")
    for i in range(hdr["ecount"]):
        e = parse_entry(data, i, hdr["esize"])
        if e:
            size_gb = (e["last"] - e["first"] + 1) * SECTOR / 1e9
            recovery = "  [recoveryOS]" if e["type"] == RECOVERY_TYPE else ""
            print(f"  #{i+1}: LBA {e['first']:>12} - {e['last']:>12}  {size_gb:7.2f} GB  "
                  f"{e['name'] or '(unnamed)'}  type={e['type']}{recovery}")

def write_gpt(f, hdr, data):
    ecrc = zlib.crc32(data) & 0xFFFFFFFF
    raw = bytearray(hdr["raw"][:hdr["hsize"]])
    struct.pack_into("<I", raw, 88, ecrc)         # entries CRC
    struct.pack_into("<I", raw, 16, 0)            # zero header CRC for compute
    hcrc = zlib.crc32(bytes(raw)) & 0xFFFFFFFF
    struct.pack_into("<I", raw, 16, hcrc)
    f.seek(hdr["elba"] * SECTOR); f.write(data)
    f.seek(hdr["lba"] * SECTOR); f.write(raw)

def remove(f, num, force=False):
    primary = read_header(f, 1)
    backup = read_header(f, primary["backup"])
    pdata = read_entries(f, primary)
    bdata = read_entries(f, backup)
    e = parse_entry(pdata, num - 1, primary["esize"])
    if e is None:
        raise SystemExit(f"partition #{num} is already empty")
    if e["type"] != RECOVERY_TYPE and not force:
        raise SystemExit(f"refusing: #{num} ({e['name'] or 'unnamed'}, type={e['type']}) "
                         f"is not the recoveryOS partition; pass --force to override")
    print(f"removing #{num}: {e['name'] or '(unnamed)'} "
          f"({(e['last']-e['first']+1)*SECTOR/1e9:.2f} GB, type={e['type']})")
    for data in (pdata, bdata):
        off = (num - 1) * primary["esize"]
        data[off:off + primary["esize"]] = b"\x00" * primary["esize"]
    write_gpt(f, primary, pdata)
    write_gpt(f, backup, bdata)
    print("done: entry zeroed in primary + backup GPT, CRCs rewritten")

def find_recovery(f):
    hdr = read_header(f, 1)
    data = read_entries(f, hdr)
    hits = [parse_entry(data, i, hdr["esize"]) for i in range(hdr["ecount"])]
    hits = [e for e in hits if e and e["type"] == RECOVERY_TYPE]
    if not hits:
        raise SystemExit("no recoveryOS partition found (already removed?)")
    if len(hits) > 1:
        raise SystemExit(f"found {len(hits)} recoveryOS partitions "
                         f"(#{', #'.join(str(e['i']+1) for e in hits)}); "
                         f"use `remove <n>` to pick one explicitly")
    return hits[0]["i"] + 1

def guard_path(path, writing):
    st = os.stat(path)
    if not stat.S_ISREG(st.st_mode):
        raise SystemExit(f"refusing: {path} is not a regular file "
                         f"(this tool never operates on device nodes)")
    if writing and attached(path):
        raise SystemExit(f"refusing: {path} is attached (hdiutil); detach it first")

def attached(path):
    """Return whether hdiutil reports this image attached; abort if unknown."""
    try:
        result = subprocess.run(["hdiutil", "info", "-plist"],
                                capture_output=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise SystemExit(f"could not determine whether the image is attached: {exc}")
    if result.returncode != 0:
        detail = result.stderr.decode(errors="replace").strip()
        suffix = f": {detail}" if detail else ""
        raise SystemExit("could not determine whether the image is attached "
                         f"(hdiutil exited {result.returncode}){suffix}")
    try:
        out = result.stdout
        info = plistlib.loads(out)
    except (plistlib.InvalidFileException, ExpatError, ValueError, TypeError) as exc:
        raise SystemExit(f"could not determine whether the image is attached: "
                         f"invalid hdiutil response ({exc})")
    images = info.get("images") if isinstance(info, dict) else None
    if not isinstance(images, list) or any(
            not isinstance(img, dict) or
            not isinstance(img.get("image-path"), str) or
            not img["image-path"] or not os.path.isabs(img["image-path"])
            for img in images):
        raise SystemExit("could not determine whether the image is attached: "
                         "invalid hdiutil response structure")
    target = os.path.realpath(path)
    return any(os.path.realpath(img.get("image-path", "")) == target
               for img in images)

if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--force"]
    force = "--force" in sys.argv
    if len(args) < 2 or args[0] not in ("list", "remove", "remove-recovery"):
        raise SystemExit(__doc__)
    mode, path = args[0], args[1]
    guard_path(path, writing=(mode != "list"))
    with open(path, "rb" if mode == "list" else "r+b") as f:
        if mode == "list":
            show(f)
        elif mode == "remove-recovery":
            remove(f, find_recovery(f), force=False)
        else:
            remove(f, int(args[2]), force=force)
