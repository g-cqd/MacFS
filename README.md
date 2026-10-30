# MacFS

Read Btrfs, NTFS and ext2/3/4 volumes on macOS, natively and read-only.

- **FSKit modules** (macOS 27): `mount -F -t btrfs|ext4|ntfsro /dev/diskNsM /path` once a signed module is enabled in System Settings →
  General → Login Items & Extensions → File System Extensions. Signing needs the FSKit Module capability (docs/roadmap/0006).
- **The MacFS app** browses a disk image with the same readers and exports files, with nothing installed.
- **Planned:** loopback proxies through macOS's own NFS and WebDAV clients (no entitlement needed), kernel-offloaded I/O, writes.

Hot loops are arm64 assembly (CRC-32C with a PMULL fold, NEON bit count and UTF-16 narrowing), each tested against a C reference and
benchmarked against compiler intrinsics. See [docs/WHITE-PAPER.md](docs/WHITE-PAPER.md), [docs/DESIGN.md](docs/DESIGN.md) and
[AGENTS.md](AGENTS.md).
