---
status: done
blocked-by: []
date: 2026-10-30
---

# 0004 — ext2/3/4 reader, read-only

## Done

Red first. Five images (1 KiB blocks and indirect maps, journal, extents and htree, inline data, bigalloc). Two surviving mutants
(the unwritten-extent boundary, inline data past 60 bytes) became tests that kill them.
