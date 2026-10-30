# Conformance

What each reader is held to, and how. Four kinds of reference, in this order of authority:

1. **The reference implementation**, which defines behaviour where documents are silent: the Linux kernel for ext2/3/4, ntfs-3g
   for NTFS, btrfs-progs for Btrfs (this kernel has no Btrfs driver), liblzo2 and zlib for the codecs. Each test image has a
   `<image>.reference` manifest written by that implementation (`Scripts/make-test-images.inner.sh`): every node's type, mode,
   owner, link count, size, times and content, with a `fields` line naming what that implementation owns. `*ConformanceTests`
   compare every owned field of every node.
2. **The reference documentation**: the kernel's `Documentation/filesystems/ext4/`, `fs/ext4/*.c` for checksums, Microsoft's
   [MS-FSCC] and the ntfs-3g/ntfsprogs sources for NTFS, `Documentation/filesystems/btrfs.rst` and btrfs-progs' on-disk notes.
   Each format page lists the sections implemented and the ones refused.
3. **Standards**: CRC-32C (RFC 3720 B.4 vectors), DEFLATE/zlib (RFC 1950, 1951), UTF-16 (Unicode §3.9).
4. **The reference test suites**: e2fsprogs v1.47.2 `tests/f_*` (190 damaged ext images with e2fsck's verdict) and btrfs-progs
   v6.14 `tests/` (136 images, dumps restored with `btrfs-image -r`), fetched by `macfs-tool images --corpus` into `TestCorpus/`.
   `ReferenceSuiteTests`: on every image a reader ends with a result or a `DiskError`, never a trap or a hang; where e2fsck's
   expected output is only its passes (16 images), the whole tree reads, or the reader names what it does not support.

Pages: [ext](ext.md), [NTFS](ntfs.md), [Btrfs](btrfs.md), [performance](performance.md).
