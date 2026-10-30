---
status: done
blocked-by: []
date: 2026-10-30
---

# 0018 — Kernel-offloaded I/O

FSKit's blockmap for uncompressed extents and runs, so the kernel reads data blocks itself (msdos ships with it on).

Measured need (docs/conformance/performance.md): mounted, the modules read large files at 87 to 93% of Apple's FSKit exFAT module,
which offloads; the readers alone are at native speed.

## Done

Each reader maps its files (`BlockMapping`: ext runs, NTFS data runs, Btrfs extents through the chunk map; holes and unwritten
extents as zero fill), and the volume answers FSKit's `KernelOffloadedIOHandler`; the modules declare `FSSupportsKernelOffloadedIO`
as Apple's msdos module does. Files not stored as their bytes (inline, compressed, resident, an NTFS stream initialized short of
its size) carry `inhibitKernelOffloadedIO` and keep the module's `read`. Btrfs verifies a range's data checksums before the kernel
reads it: a flipped data byte reads as EIO through a mount. Oracle: every mappable file of every image, assembled from its map
by reading the device, equals `read` (`BlockMapTests`); the NTFS image carries stale bytes past an initialized size, so a map that
reached them would show. Mounted, large files: ext4 14.5, NTFS 15.8, Btrfs 15.9 GB/s (Apple's exFAT 15.6, APFS 16.6).
