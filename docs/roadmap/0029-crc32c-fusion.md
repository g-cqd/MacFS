---
status: open
blocked-by: []
date: 2026-10-30
---

# 0029 — CRC-32C fusion: scalar streams beside the vector folds

The integer pipes are idle while the vector pipes fold. Run three `crc32cx` streams over their own regions in the same loop and combine
them with shift constants for a fixed outer block (corsix/fast-crc32 `v9s3x2e_s3`, reported 85 GB/s on M1). The 4 KiB block is the
natural outer size: it is what Btrfs and ext4 checksum.
