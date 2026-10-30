# More file systems: which, in what order, held to what (2026-10-30)

What macOS 27 reads itself (`/System/Library/Filesystems`, this machine): APFS, HFS+, FAT, exFAT, UDF, ISO 9660, NTFS
(read-only), plus network and virtual ones. MacFS adds what it does not. Each candidate must have a reference implementation this
machine can run (docs/conformance): the Linux kernel in Apple's `container` has drivers for ext2/3/4, XFS, EROFS and FUSE
(`/proc/filesystems`); Alpine 3.22 packages the reference tools listed.

| Format | Where it is met | Reference here | Docs | Fit | Order |
|---|---|---|---|---|---|
| XFS | Linux servers and NAS (RHEL's default) | **Kernel driver**; xfsprogs 6.14 (`xfs_db`, `xfs_repair -n`); xfstests exists | "XFS Algorithms & Data Structures" (kernel docs) | B+trees, extents, directories in four forms, v5 CRC metadata: the ext/Btrfs machinery reused | 1 |
| EROFS | Android system images, container images | **Kernel driver**; erofs-utils 1.8 (`mkfs.erofs`, `fsck.erofs`) | `Documentation/filesystems/erofs.rst` | Read-only by design, small, LZ4/LZMA compression | 2 |
| SquashFS | Live media, firmware, snaps | squashfs-tools 4.6 (`unsquashfs` as the reference reader; no kernel driver in this container) | squashfs-tools' format notes | Read-only by design; gzip, xz, LZO (ours), LZ4, zstd (0013) | 2 |
| HFS (standard) | Disks from Macs before 1998, archives | None packaged (hfsprogs is HFS+ only) | Inside Macintosh: Files | A gap macOS itself opened: Apple dropped HFS standard in 10.15 (reported, not checked here) | 4 |
| F2FS | Android phones, SD cards | f2fs-tools 1.16 (`fsck.f2fs`, `dump.f2fs`); no kernel driver here | Kernel `Documentation/filesystems/f2fs.rst` | Log-structured; checkpoint and NAT/SIT tables | 3 |
| UFS2 | FreeBSD | Nothing packaged | FreeBSD sources | Small, little demand | 5 |
| ZFS | NAS (TrueNAS), servers | zfs 2.3 packaged (userspace `zdb`) | OpenZFS on-disk spec (dated) | Large (pools, vdevs, raidz, compression, encryption); OpenZFS on OS X exists | Not planned |
| JFS, NILFS2, bcachefs | Rare; bcachefs left mainline | Tools packaged | Sparse | Low demand | Not planned |
| exFAT, FAT, UDF, ISO 9660, HFS+, APFS | — | — | — | macOS reads them | Not needed |

Each new format follows the existing ones: a reader behind `ReadOnlyFileSystem`, images and `.reference` manifests from its
reference tools (the kernel where it has a driver), the reference test suites where they exist, a module per format (ADR-0006),
and the native baseline (docs/conformance/performance.md). Roadmap 0031 to 0034.
