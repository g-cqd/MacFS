---
status: open
blocked-by: []
date: 2026-10-30
---

# 0040 — A read amplification budget

Everest's `MediaBlockCache` measures bytes pulled per byte asked, and reads ahead only once reads march forward (research
2026-10-30-everest-code-review #15). In MacFS the amplifiers are compressed extents (a 4 KiB read of a 128 KiB zstd extent, with a
cache of 64 decoded extents in Btrfs), metadata walks per read, and the proxy's request sizes. A test per reader holds device bytes
and decoded bytes per byte returned, for sequential and scattered reads, under a budget; read-ahead is added only where the test
shows it pays.
