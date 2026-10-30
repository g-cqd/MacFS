---
status: accepted
supersedes: ["0003"]
date: 2026-10-30
---

# 0011 — CRC-32C folds eight PMULL lanes; assembly stays where it measures ahead

## Context

ADR-0003 kept assembly where it measured ahead of intrinsics and recorded the CRC kernel as equal to intrinsics on one large buffer,
a third of the published state of the art. Roadmap 0011 replaced the kernel's main loop.

## Decision

The rule of ADR-0003 stands: hand-written arm64 assembly only where it measures ahead of the same algorithm in intrinsics, each kernel
with a portable C reference as its oracle. The CRC kernel now folds eight 128-bit accumulators 128 bytes per iteration with PMULL from
256 bytes on, merges them with 16-byte folds and reduces with two `crc32cx`; the three-stream code remains for shorter inputs and
tails. Plain `eor`, not SHA3's `eor3`: `eor3` measured 3% faster at 4 KiB and equal elsewhere, and would need a runtime check this
kernel does not have.

## Evidence (Apple M2 Pro, release, median of nine, `fskbench`)

| Case | before | eight-lane fold, intrinsics | eight-lane fold, assembly |
|---|---:|---:|---:|
| 64 MiB | 24.6 GB/s | 52.1 | 58.7 |
| 4 KiB blocks | 23.4 | 50.4 | 56.8 |
| 16 KiB blocks | 24.3 | 51.5 | 58.5 |

Bit count (2.9x) and UTF-16 narrowing (5.8x) are unchanged from ADR-0003. A guard-page test puts every input before an inaccessible
page; a mutant that starts the loop with 120 bytes left crashes it.

## Consequences

Published results for CRC (corsix/fast-crc32 on M1, reported) are 77 to 85 GB/s with scalar CRC streams beside the vector folds;
roadmap 0029 owns that step.
