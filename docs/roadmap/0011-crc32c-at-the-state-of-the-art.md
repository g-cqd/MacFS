---
status: open
blocked-by: []
date: 2026-10-30
---

# 0011 — CRC-32C at the state of the art

Vector PMULL folding of many accumulators beside scalar streams (corsix/fast-crc32 `v9s3x2e_s3`, dougallj): reported 77 to 85 GB/s on M1
against 24.6 here. Keep the 4 KiB block case first-class: that is what Btrfs and ext4 checksum.
