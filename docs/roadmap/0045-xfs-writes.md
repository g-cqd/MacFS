---
status: open
blocked-by: ["0017"]
date: 2026-10-30
---

# 0045 — Writes for XFS

The reader is done (0031, 0037). Writing v5 means: free space in both allocation B+trees (by block and by size), inode allocation
in the inode and free-inode B+trees (sparse inodes), the reverse-mapping and reference-count B+trees that mkfs.xfs 6.14 enables by
default (rmapbt, reflink), every block's CRC, owner and LSN, directories in all four forms with the hash leaves kept in order, and the
log: changes go through it so a crash replays, and a volume whose log needs recovery is refused for writing. Volumes with features
the writer does not maintain (realtime, an unknown incompatible bit) stay read-only, by name. Checked after every test by
`xfs_repair -n` in the container and a tree compared through the kernel driver.
