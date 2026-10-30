---
status: done
blocked-by: []
date: 2026-10-30
---

# 0011 — CRC-32C at the state of the art

Vector PMULL folding of many accumulators beside scalar streams (corsix/fast-crc32 `v9s3x2e_s3`, dougallj): reported 77 to 85 GB/s on M1
against 24.6 here. Keep the 4 KiB block case first-class: that is what Btrfs and ext4 checksum.

## Done

Eight-lane PMULL fold (ADR-0011): 24.6 to 58.7 GB/s on 64 MiB, 23.4 to 56.8 at 4 KiB, 1.13x the same fold in intrinsics. Red first
(a merge without folds: 3420 failures), guard-page overread test with a mutant that crashes it. The reported 77 to 85 GB/s needs the
fused scheme: roadmap 0029.
