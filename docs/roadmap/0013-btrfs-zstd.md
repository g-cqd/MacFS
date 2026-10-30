---
status: done
blocked-by: []
date: 2026-10-30
---

# 0013 — zstd extents for Btrfs

A bounds-checked zstd frame decoder (Compression has no zstd). The `btrfs-zstd` image already exists and reads `unsupported`.

## Done

`Sources/CFSKernels/zstd.c` (RFC 8878, from the RFC): frames, raw/RLE/compressed blocks, Huffman literals in 1 or 4 streams,
FSE sequence tables (predefined, RLE, described, repeat), repeat offsets, the content checksum; dictionaries refused. Btrfs
reads one frame per extent and ignores the sector padding after it. Oracles: the zstd CLI's frames (TestImages/zstd), zstd
1.5.7's golden files and 1,000 decodecorpus frames, and libzstd's one-shot verdicts on 2,400 damaged frames and 87,008
single-bit flips (TestCorpus/zstd); the btrfs-zstd image against btrfs-progs' restore. Speed: docs/research/2026-10-30-
compression-kernels.md.
