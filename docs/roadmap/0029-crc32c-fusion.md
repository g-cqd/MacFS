---
status: done
blocked-by: []
date: 2026-10-30
---

# 0029 — CRC-32C fusion: scalar streams beside the vector folds

The integer pipes are idle while the vector pipes fold. Run three `crc32cx` streams over their own regions in the same loop and combine
them with shift constants for a fixed outer block (corsix/fast-crc32 `v9s3x2e_s3`, reported 85 GB/s on M1). The 4 KiB block is the
natural outer size: it is what Btrfs and ext4 checksum.

## Done

In aemi (its diary 2026-10-30-03, commit `ed87cf8`): three `crc32cx` streams beside the eight PMULL folds in 4 KiB chunks, each from
seed 0 and shifted into place so chunks overlap. In cache 67 to 70 GB/s became 86 to 90; from DRAM all variants meet the memory's 59.
Larger chunks lost from DRAM (64 KiB: 43, 16 KiB: 38); a tree merge lost on short inputs. FSCore uses it (ADR-0012).
