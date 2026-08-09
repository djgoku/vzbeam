#!/usr/bin/env python3
"""List or remove a GPT partition entry in a raw disk image (e.g. a VZ disk.img).

Usage:
  gptedit.py list <disk.img>
  gptedit.py remove <disk.img> <partition-number>   # 1-based, as shown by list

Removing zeroes the partition's entry in BOTH the primary and backup GPT
entry arrays and rewrites the entries-CRC and header-CRC in both headers.
The partition's data blocks are left in place (orphaned), which is exactly
what "delete the recovery partition" means for our purposes.
"""
import struct, sys, uuid, zlib

SECTOR = 512

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
            print(f"  #{i+1}: LBA {e['first']:>12} - {e['last']:>12}  {size_gb:7.2f} GB  "
                  f"{e['name'] or '(unnamed)'}  type={e['type']}")

def write_gpt(f, hdr, data):
    ecrc = zlib.crc32(data) & 0xFFFFFFFF
    raw = bytearray(hdr["raw"][:hdr["hsize"]])
    struct.pack_into("<I", raw, 88, ecrc)         # entries CRC
    struct.pack_into("<I", raw, 16, 0)            # zero header CRC for compute
    hcrc = zlib.crc32(bytes(raw)) & 0xFFFFFFFF
    struct.pack_into("<I", raw, 16, hcrc)
    f.seek(hdr["elba"] * SECTOR); f.write(data)
    f.seek(hdr["lba"] * SECTOR); f.write(raw)

def remove(f, num):
    primary = read_header(f, 1)
    backup = read_header(f, primary["backup"])
    pdata = read_entries(f, primary)
    bdata = read_entries(f, backup)
    e = parse_entry(pdata, num - 1, primary["esize"])
    if e is None:
        raise SystemExit(f"partition #{num} is already empty")
    print(f"removing #{num}: {e['name'] or '(unnamed)'} "
          f"({(e['last']-e['first']+1)*SECTOR/1e9:.2f} GB, type={e['type']})")
    for data in (pdata, bdata):
        off = (num - 1) * primary["esize"]
        data[off:off + primary["esize"]] = b"\x00" * primary["esize"]
    write_gpt(f, primary, pdata)
    write_gpt(f, backup, bdata)
    print("done: entry zeroed in primary + backup GPT, CRCs rewritten")

if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in ("list", "remove"):
        raise SystemExit(__doc__)
    mode, path = sys.argv[1], sys.argv[2]
    with open(path, "rb" if mode == "list" else "r+b") as f:
        if mode == "list":
            show(f)
        else:
            remove(f, int(sys.argv[3]))
