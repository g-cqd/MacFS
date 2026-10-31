---
status: open
blocked-by: []
date: 2026-10-30
---

# 0017 — Writable disks

The owner's requirement: disks should be writable, not only readable, on every file system MacFS reads. Before any write code, one
ADR that every format's write path follows: crash consistency (what is on disk after power loss at any point), the read-only default
and how a user opts in, refusal rules (a dirty NTFS volume, a hibernated Windows, an ext4 journal or an XFS log that needs recovery,
unknown features), and the test oracle (the Linux tools' own checkers and a tree compared after writes). Then one entry per format,
each behind its own gate, and one for the mount paths that carry the writes:

| Format | Entry | Oracle after every test |
|---|---|---|
| ext2, ext3, ext4 | 0026 | `e2fsck -fn` |
| NTFS | 0027 | `ntfsfix -n`, a tree compare through ntfs-3g |
| Btrfs | 0028 | `btrfs check --readonly` |
| XFS | 0045 | `xfs_repair -n` |
| F2FS | after its reader (0033) | `fsck.f2fs` |
| EROFS, SquashFS | none: read-only formats (0032) | — |
| HFS standard | none until a reference exists (0034) | — |
| The mount paths: FSKit, NFS proxy, WebDAV, File Provider | 0046 | the same checkers, after writes made through each path |
