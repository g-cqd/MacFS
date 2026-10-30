---
status: open
blocked-by: []
date: 2026-10-30
---

# 0017 — Writable disks

The owner's requirement: disks should be writable, not only readable. Before any write code, one ADR that every format's write path
follows: crash consistency (what is on disk after power loss at any point), the read-only default and how a user opts in, refusal
rules (a dirty NTFS volume, a hibernated Windows, an ext4 journal that needs recovery, unknown features), and the test oracle (the
Linux tools' own checkers: `e2fsck -fn`, `btrfs check`, `ntfsfix -n`, and a tree compared after writes). Then one entry per format,
each behind its own gate.
