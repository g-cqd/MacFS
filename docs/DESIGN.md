# MacFS design

## Layers

| Layer | Where | What |
|---|---|---|
| Kernel-offloaded I/O | `Extensions/Shared/ReadOnlyVolume+KernelOffloadedIO.swift`, `BlockMapping` in each reader | The kernel reads mappable files from the device itself; the module says where (ADR-0012, roadmap 0018). Inline, compressed and resident files stay with the module; Btrfs verifies checksums before the kernel reads. |
| Kernels | `Packages/FSCore/Sources/CFSKernels`, aemi's `AemiKernels` | MacFS's own: the NTFS fixups in arm64 assembly, portable C elsewhere and compiled everywhere as `fsk_ref_*`, the test oracle; the device ioctls. From aemi (ADR-0012): CRC-32C (PMULL folds with three `crc32cx` streams from 4 KiB), bit count (NEON `cnt`), UTF-16LE→ASCII (`umaxv`, `xtn`). |
| Core | `FSCore` | `DiskError`, `DiskBytes` (bounds-checked loads), `BlockSource` and `FileBlockSource` (image or raw device), `AlignedReader`, `BoundedCache`, `TreeWalk`, the model (`NodeAttributes`, `DirectoryEntry`, `VolumeDescription`) and the seam: `ReadOnlyFileSystem`. |
| Readers | `Btrfs`, `NTFS`, `ExtFS` | One `ReadOnlyFileSystem` each. Synchronous, thread-safe, caches bounded. |
| Registry | `Formats` | `DiskFormat`: names, short names, probe (a full open), open. The one list every consumer uses. |
| Mount glue | `MountKit` | `MountedTree`: identifiers (root = 2, parent of root = 1), listings with `.` and `..`, cookies (proved in Lean, `Proofs/`). The mount seam (ADR-0013): `MountBackend`, `MountService` (registry first, make before break, sweep), `SystemMountTable`; its lifecycle in TLA+ (`docs/models/MountLifecycle.tla`). |
| Mount registry | `MountRegistry` | The registry on disk: protobuf (AemiProtobuf) in a CRC-32C envelope, atomic writes (ADR-0015). Linked by the app, the agent and `macfs-nfsd`, never by the FSKit extensions. |
| NFS proxy | `NFSProxy`, `macfs-nfsd` | NFSv3 and MOUNT v3, read-only, over loopback TCP (ADR-0010, ADR-0014): `NFSDispatcher` is a call-to-reply function over `MountedTree` whose only state is whether its export (`NFSExport`: a secret path, mounted once, a secret in every handle) was mounted; `LoopbackServer` is the socket shell, with bounded connections and a connection's calls answered concurrently; `NFSMountCommand` mounts it soft, so a dead proxy is unmounted by the kernel. |
| FSKit | `Extensions/Shared`, one `@main` per format | `ReadOnlyModule` (`FSUnaryFileSystem`), `ReadOnlyVolume` (`FSVolume.Handler`, `ReadWriteHandler`, macOS 27 API). |
| App | `App` | Module status, a link to the extension settings, and an in-app browser over the same readers. Mounting from the app goes through one backend seam, and proxy mounts belong to a launchd agent (ADR-0013; roadmap 0035, 0039). |
| Tooling | `Packages/Tooling` | `macfs-tool` and its command plugins: images, gates, plists. |

## Readers, as built

**Btrfs.** Newest valid superblock of the three copies (checksum verified: CRC-32C, xxHash64 or SHA-256). Chunk map bootstrapped from the
superblock's system array, then the chunk tree; SINGLE, DUP and RAID1* read from this device, striped profiles refused when read. Tree
search is a bounded range walk. The default subvolume is mounted; nested subvolumes are directories whose inodes carry the tree in the
upper 32 bits. Extents: inline, regular, preallocated, holes; zlib (header checked, MacFS's own inflate), LZO (own bounds-checked
LZO1X) and zstd (own decoder, its sequence loop in arm64; roadmap 0013).

**NTFS.** Boot sector, `$MFT` bootstrapped from record 0 (attribute lists followed), fixups through the assembly kernel. Streams join
their extents and refuse compressed and encrypted data. Directories read `$INDEX_ROOT` and every reachable INDX block, sort by `$UpCase`
folding, hide DOS names and system records. Reparse points: Windows symlinks, junctions, WSL symlinks. Free space: `$Bitmap` through the
NEON bit count.

**ext2/3/4.** Metadata checksums where the volume has them (metadata_csum: superblock, group descriptors, inodes, extent and directory blocks, as Linux computes them; htree nodes not yet), group descriptors (32 or 64 bytes), inodes, extent trees (unwritten extents read as
holes), indirect blocks, inline data (`system.data`), linear and htree directories by linear scan. Refused: meta_bg, compression,
journal devices, dirdata. The journal is not replayed.

**XFS (v5).** Big-endian; inode numbers encode allocation group, block and slot. Inodes v3 with their CRC (bigtime and
nrext64 when set), data forks local, as extent lists or B+trees (`BMA3` blocks, checksum and owner checked), directories by
their data blocks in every form, names looked up by `xfs_da_hashname` through the hash leaves and node tree (`DA3N`, `LEAFN`;
the next leaf while a hash run goes on), symlinks inline or remote (`XSLM`), unwritten extents read as zero. Refused: v4,
ASCII case-insensitive volumes, needsrepair, realtime files. The log is not replayed (docs/conformance/xfs.md).

## What is not built

Writes (every format and every mount path, roadmap 0017), the WebDAV proxy, disk discovery in the app, mounting from the app and its
agent, the kernel-extension tier. See `docs/roadmap/`.
