---
status: open
blocked-by: []
date: 2026-10-30
---

# 0026 — Writes for ext2/3/4

Allocation in the bitmaps and group descriptors, extents and indirect blocks, directories (linear and htree, with the hashes 0016
checks), metadata checksums where the volume has them, and the journal (jbd2) for ext3/4 so a crash replays. ext2 has no journal: a
volume not cleanly unmounted is refused for writing until `e2fsck` has run, as Linux marks it. Checked after every test by `e2fsck -fn`
in the container.

## Progress

1. **Done (2026-11-01):** ext2 overwrites, without a journal or metadata checksums: bytes inside a file's stored blocks, its
   change and modification times (with nanoseconds where the inode has room). The volume is marked not clean, its mount counted
   and flushed before any change; clean again at `close`, after a flush. Refused by name: a journal, metadata checksums,
   multiple-mount protection, unknown read-only features, a volume not cleanly unmounted, a read-only device, symlinks, inline
   or encrypted files, and anything needing allocation (growing, holes). `e2fsck -fn` accepts the volume after writes and every
   crash state; the two crash invariants of ADR-0018 hold on every state. 13 tests; every mutant killed.
2. Allocation: block and inode bitmaps, group descriptors and the superblock's counts; growing a file, filling holes.
3. Create, remove, rename and link: directory entries (linear, then htree), inode allocation and link counts.
4. Metadata checksums (ext4's `metadata_csum`), then jbd2 for ext3/4.
5. Through FSKit: the volume's write handlers, the kernel-offloaded write mapping, the FSKit check (roadmap 0046).
