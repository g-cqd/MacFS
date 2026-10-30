---
status: accepted
date: 2026-10-30
---

# 0003 — Assembly kernels only where measured, with a C reference as oracle

## Context

The request was NEON assembly. AemiRegex measured the opposite answer for its prefilter (its ADR-0004: Swift SIMD within 1.0 to 1.4x of C,
no assembly). The question here is the same and was measured again for these loops (research 2026-10-30-neon-kernels, `fskbench`).

## Decision

Four kernels are hand-written arm64 assembly in `CFSKernels`, each with a portable C reference compiled on every target under
`fsk_ref_*`, which is both the non-arm64 implementation and the oracle the assembly is tested against (every length 0 to 1100 and the
tier boundaries, misaligned starts, random fixup headers). Swift wrappers check every result.

## Evidence (M-series, release, 64 MiB, median of nine)

| Kernel | C baseline | assembly | ratio |
|---|---:|---:|---:|
| CRC-32C, one buffer | 24.3 GB/s (same fold, intrinsics) | 24.6 | 1.0x |
| CRC-32C, 4 KiB blocks | 17.7 (intrinsics, one tier) | 23.4 | 1.3x, from the 768-byte tier, not codegen |
| Bit count | 21.0 (`__builtin_popcountll`) | 60.0 | 2.9x |
| UTF-16LE to ASCII | 3.9 (loop) | 22.5 | 5.8x |

## Consequences

For one large CRC buffer, assembly gains nothing over intrinsics: it stays because the two-tier layout is what wins at block sizes, and
porting that to intrinsics is a roadmap question, not a given. Published PMULL-folding CRC reaches 77 to 85 GB/s on M1 (reported by
corsix/fast-crc32): the kernel is a third of that (roadmap 0011).
