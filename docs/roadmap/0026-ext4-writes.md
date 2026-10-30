---
status: open
blocked-by: ["0017"]
date: 2026-10-30
---

# 0026 — Writes for ext2/3/4

Allocation in the bitmaps and group descriptors, extents, directories (linear and htree), and the journal (jbd2) for ext3/4 so a crash
replays. Checked after every test by `e2fsck -fn` in the container.
