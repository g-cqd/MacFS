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
