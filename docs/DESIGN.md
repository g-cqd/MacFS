# MacFS design

## Layers

| Layer | Where | What |
|---|---|---|
| Kernel-offloaded I/O | `Extensions/Shared/ReadOnlyVolume+KernelOffloadedIO.swift`, `BlockMapping` in each reader | The kernel reads mappable files from the device itself; the module says where (ADR-0012, roadmap 0018). Inline, compressed and resident files stay with the module; Btrfs verifies checksums before the kernel reads. |
| Kernels | `Packages/FSCore/Sources/CFSKernels`, aemi's `AemiKernels` | MacFS's own: the NTFS fixups in arm64 assembly, portable C elsewhere and compiled everywhere as `fsk_ref_*`, the test oracle; the device ioctls. From aemi (ADR-0012): CRC-32C (PMULL folds with three `crc32cx` streams from 4 KiB), bit count (NEON `cnt`), UTF-16LE→ASCII (`umaxv`, `xtn`). |
| Core | `FSCore` | `DiskError`, `DiskBytes` (bounds-checked loads), `BlockSource` and `FileBlockSource` (image or raw device), `AlignedReader`, `BoundedCache`, `TreeWalk`, the model (`NodeAttributes`, `DirectoryEntry`, `VolumeDescription`) and the seam: `ReadOnlyFileSystem`. |
| Readers | `Btrfs`, `NTFS`, `ExtFS` | One `ReadOnlyFileSystem` each. Synchronous, thread-safe, caches bounded. |
| Registry | `Formats` | `DiskFormat`: names, short names, probe (a full open), open. The one list every consumer uses. |
| Mount glue | `MountKit` | `MountedTree`: identifiers (root = 2, parent of root = 1), listings with `.` and `..`, cookies (proved in Lean, `Proofs/`). |
| NFS proxy | `NFSProxy`, `macfs-nfsd` | NFSv3 and MOUNT v3, read-only, over loopback TCP (ADR-0010): `NFSDispatcher` is a pure call-to-reply function over `MountedTree`; `LoopbackServer` is the socket shell. |
| FSKit | `Extensions/Shared`, one `@main` per format | `ReadOnlyModule` (`FSUnaryFileSystem`), `ReadOnlyVolume` (`FSVolume.Handler`, `ReadWriteHandler`, macOS 27 API). |
| App | `App` | Module status, a link to the extension settings, and an in-app browser over the same readers. |
| Tooling | `Packages/Tooling` | `macfs-tool` and its command plugins: images, gates, plists. |

## Readers, as built

**Btrfs.** Newest valid superblock of the three copies (checksum verified: CRC-32C, xxHash64 or SHA-256). Chunk map bootstrapped from the
superblock's system array, then the chunk tree; SINGLE, DUP and RAID1* read from this device, striped profiles refused when read. Tree
search is a bounded range walk. The default subvolume is mounted; nested subvolumes are directories whose inodes carry the tree in the
upper 32 bits. Extents: inline, regular, preallocated, holes; zlib (Compression, header checked) and LZO (own bounds-checked LZO1X);
zstd refused.

**NTFS.** Boot sector, `$MFT` bootstrapped from record 0 (attribute lists followed), fixups through the assembly kernel. Streams join
their extents and refuse compressed and encrypted data. Directories read `$INDEX_ROOT` and every reachable INDX block, sort by `$UpCase`
folding, hide DOS names and system records. Reparse points: Windows symlinks, junctions, WSL symlinks. Free space: `$Bitmap` through the
NEON bit count.

**ext2/3/4.** Metadata checksums where the volume has them (metadata_csum: superblock, group descriptors, inodes, extent and directory blocks, as Linux computes them; htree nodes not yet), group descriptors (32 or 64 bytes), inodes, extent trees (unwritten extents read as
holes), indirect blocks, inline data (`system.data`), linear and htree directories by linear scan. Refused: meta_bg, compression,
journal devices, dirdata. The journal is not replayed.

**XFS (v5).** Big-endian; inode numbers encode allocation group, block and slot. Inodes v3 with their CRC (bigtime and
nrext64 when set), data forks local, as extent lists or B+trees (`BMA3` blocks, checksum and owner checked), directories by
their data blocks in every form, symlinks inline or remote (`XSLM`), unwritten extents read as zero. Refused: v4, needsrepair,
realtime files. The log is not replayed (docs/conformance/xfs.md).

## What is not built

Kernel-offloaded I/O, writes, the WebDAV proxy, disk discovery in the app, mounting from the app, the kernel-extension tier.
See `docs/roadmap/`.
