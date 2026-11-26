#!/usr/bin/env python3
"""Create or inspect a 32768-sector (16 MiB) disk.img with XuFS superblock, inodes, and Ring 3 binaries."""

import os
import struct
import sys

SECTOR_SIZE = 512
TOTAL_SECTORS = 32768
XUFS_MAGIC = 0x5346555830303130  # "XUFS0010" little-endian
SUPER_SECTOR = 4
INODE_START = 5
INODE_SECTORS = 3
MAX_INODES = 24
DATA_START = 8
DATA_SECTORS = TOTAL_SECTORS - DATA_START

SUPER_FMT = "<QIIIIIIII"
INODE_FMT = "<IIIIII40s"


def build_disk(disk_path: str, file_specs: list[tuple[str, str]]):
    files: list[tuple[str, bytes, int]] = [
        ("/etc/motd", b"Welcome to Xu OS (XuFS on VirtIO-Blk)!\n", 1),
    ]
    for guest_path, host_path in file_specs:
        with open(host_path, "rb") as f:
            files.append((guest_path, f.read(), 2))

    buf = bytearray(TOTAL_SECTORS * SECTOR_SIZE)

    # Sector 0: host seed for blktest
    seed = b"XU-HOST-SEED-SECTOR0"
    buf[0 : len(seed)] = seed

    next_sector = DATA_START
    inode_bytes = bytearray(MAX_INODES * 64)
    for idx, (path, data, flags) in enumerate(files):
        assert idx < MAX_INODES
        path_b = path.encode("ascii")
        assert len(path_b) < 40
        sec_cnt = max(1, (len(data) + SECTOR_SIZE - 1) // SECTOR_SIZE)
        assert next_sector + sec_cnt <= TOTAL_SECTORS, f"Disk full packing {path}: {next_sector + sec_cnt} > {TOTAL_SECTORS}"
        off = next_sector * SECTOR_SIZE
        buf[off : off + len(data)] = data
        name_padded = path_b + b"\x00" * (40 - len(path_b))
        struct.pack_into(
            INODE_FMT,
            inode_bytes,
            idx * 64,
            1,
            len(data),
            next_sector,
            sec_cnt,
            flags,
            0,
            name_padded,
        )
        next_sector += sec_cnt

    struct.pack_into(
        SUPER_FMT,
        buf,
        SUPER_SECTOR * SECTOR_SIZE,
        XUFS_MAGIC,
        1,
        TOTAL_SECTORS,
        INODE_START,
        INODE_SECTORS,
        DATA_START,
        DATA_SECTORS,
        len(files),
        next_sector,
    )
    buf[INODE_START * SECTOR_SIZE : (INODE_START + INODE_SECTORS) * SECTOR_SIZE] = inode_bytes

    os.makedirs(os.path.dirname(os.path.abspath(disk_path)), exist_ok=True)
    with open(disk_path, "wb") as f:
        f.write(buf)


def read_xufs_file(disk_path: str, target_path: str) -> bytes | None:
    with open(disk_path, "rb") as f:
        buf = f.read()
    magic, ver, total_sec, in_start, in_secs, d_start, d_secs, fcnt, next_free = struct.unpack_from(
        SUPER_FMT, buf, SUPER_SECTOR * SECTOR_SIZE
    )
    if magic != XUFS_MAGIC or ver != 1:
        return None
    for idx in range(MAX_INODES):
        used, size, start_sec, sec_cnt, flags, _res, raw_name = struct.unpack_from(
            INODE_FMT, buf, in_start * SECTOR_SIZE + idx * 64
        )
        if used == 0:
            continue
        name = raw_name.split(b"\x00", 1)[0].decode("ascii", errors="replace")
        if name == target_path:
            off = start_sec * SECTOR_SIZE
            return buf[off : off + size]
    return None


def main() -> int:
    if len(sys.argv) == 4 and sys.argv[1] == "--read":
        data = read_xufs_file(sys.argv[2], sys.argv[3])
        if data is None:
            return 1
        sys.stdout.buffer.write(data)
        return 0
    if len(sys.argv) < 3:
        print(f"usage: {sys.argv[0]} <disk.img> <guest_path=host_file>...", file=sys.stderr)
        return 1
    specs: list[tuple[str, str]] = []
    for arg in sys.argv[2:]:
        if "=" in arg:
            gp, hp = arg.split("=", 1)
            specs.append((gp, hp))
        else:
            specs.append((f"/bin/{os.path.basename(arg)}", arg))
    build_disk(sys.argv[1], specs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
