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
2. **Done (2026-11-01):** block allocation on ext2 (no descriptor checksums, no clusters, indirect-mapped files): files grow
   and holes fill through the block bitmaps, the group descriptors' counts and the indirect blocks (single, double, triple),
   placed after the file's last block; the superblock's free count at `close`, as Linux writes it, and live in `statistics`.
   New data and indirect blocks are written and flushed before anything links them; a crash leaves at worst leaked blocks.
   Every crash state passes `e2fsck -fp` then `e2fsck -fn`, and none shows a new block's old contents. A gap after the old end
   reads as zeros. More than the free space is refused before anything is written (ENOSPC). 10 tests; mutants killed but for
   the search's start (a placement heuristic). Not yet: inode allocation (it comes with create), extent-mapped files.
3. Create, remove, rename and link.
   - **Done (2026-11-01):** create (files, directories) and remove (unlink, rmdir) in linear directories: inode bitmaps and the
     descriptors' inode and directory counts, entries inserted into a record's slack or a new block the directory grows by,
     removed into the record before; link counts; a removed node's blocks (data and indirect) and inode freed, its deletion
     time set. Names checked (EEXIST, ENAMETOOLONG, EINVAL; ENOTEMPTY for a directory with names). Refused: indexed (htree)
     directories, other kinds of node, a node with an extended-attribute block. The order is what preen repairs, measured on
     every crash state: blocks and bitmaps, flush, the name, flush, the inode; a remove frees the inode, flushes, then drops
     the name. 10 tests, two of them every crash state through `e2fsck -fp` then `-fn`.
   - **Done (2026-11-01):** rename (POSIX's rules: replacing a file or an empty directory, EISDIR, ENOTDIR, ENOTEMPTY, never
     into its own subtree, nothing onto itself) and hard links. A rename within one block is one write. Every crash state of
     renames within a directory, a replacing rename and a hard link is repaired by preen; a directory moved to another parent
     by `e2fsck -fy` (ADR-0018). 7 tests.
   - **Done (2026-11-01):** symbolic links (fast under 60 bytes, else in a block), sizes (truncation frees the blocks past the
     end, indirect ones included, and zeroes the rest of the last block; growth leaves a hole) and attributes (mode, owner,
     access and modification times; the change time follows). Every crash state of a truncation and of symlinks made is
     repaired by preen. 4 tests.
   - Next: htree directories.
4. Metadata checksums (ext4's `metadata_csum`), then jbd2 for ext3/4.
5. Through FSKit: the volume's write handlers, the kernel-offloaded write mapping, the FSKit check (roadmap 0046).
