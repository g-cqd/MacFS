# MacFS

Read Btrfs, NTFS, ext2/3/4 and XFS volumes on macOS, natively and read-only.

- **FSKit modules** (macOS 27): `mount -F -t btrfs|ext4|ntfsro /dev/diskNsM /path` once a signed module is enabled in System Settings →
  General → Login Items & Extensions → File System Extensions. Signing needs the FSKit Module capability (docs/roadmap/0006).
- **The MacFS app** browses a disk image with the same readers and exports files, with nothing installed.
- **Linux disks mount on their own** when attached (Btrfs and ext, partitioned or not); NTFS goes to macOS's own driver unless mounted
  with `mount -F -t ntfsro`.
- **No extension at all:** `macfs-nfsd <image>` serves a volume over NFSv3 on loopback and prints the `mount_nfs` command for macOS's
  own client: soft, so the mount goes away if the proxy dies, at a secret export that admits that one mount.
- **Planned:** mounting from the app through one seam, with proxy mounts kept by a launchd agent (ADR-0013); a WebDAV option;
  writes on every format MacFS reads and through every mount path (roadmap 0017).

Hot loops are SIMD kernels: CRC-32C (PMULL folds with scalar streams beside them), NEON bit count and UTF-16 narrowing from aemi, and
the NTFS fixups in arm64 assembly; each is tested against a reference, at inaccessible page edges, and benchmarked (ADR-0012). See [docs/WHITE-PAPER.md](docs/WHITE-PAPER.md), [docs/DESIGN.md](docs/DESIGN.md) and
[AGENTS.md](AGENTS.md).

## License

MIT; see [LICENSE](LICENSE).
