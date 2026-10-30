# MacFS design

## Layers

| Layer | Where | What |
|---|---|---|
| Kernels | `Packages/FSCore/Sources/CFSKernels` | arm64 assembly: CRC-32C (three streams, PMULL fold, two tiers), NTFS fixups, bit count (NEON `cnt`), UTF-16LE→ASCII (`umaxv`, `xtn`). Portable C for other targets, compiled everywhere as `fsk_ref_*`, the test oracle. |
| Core | `FSCore` | `DiskError`, `DiskBytes` (bounds-checked loads), `BlockSource` and `FileBlockSource` (image or raw device), `AlignedReader`, `BoundedCache`, `TreeWalk`, the model (`NodeAttributes`, `DirectoryEntry`, `VolumeDescription`) and the seam: `ReadOnlyFileSystem`. |
| Readers | `Btrfs`, `NTFS`, `ExtFS` | One `ReadOnlyFileSystem` each. Synchronous, thread-safe, caches bounded. |
| Registry | `Formats` | `DiskFormat`: names, short names, probe (a full open), open. The one list every consumer uses. |
| Mount glue | `MountKit` | `MountedTree`: identifiers (root = 2, parent of root = 1), listings with `.` and `..`, cookies (proved in Lean, `Proofs/`). |
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

**ext2/3/4.** Superblock checksum (metadata_csum), group descriptors (32 or 64 bytes), inodes, extent trees (unwritten extents read as
holes), indirect blocks, inline data (`system.data`), linear and htree directories by linear scan. Refused: meta_bg, compression,
journal devices, dirdata. The journal is not replayed.

## What is not built

Kernel-offloaded I/O, writes, the loopback proxies, disk discovery in the app, mounting from the app, the kernel-extension tier.
See `docs/roadmap/`.
