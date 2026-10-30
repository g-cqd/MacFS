---
status: accepted
supersedes: ["0011"]
date: 2026-10-30
---

# 0012 — Generic kernels come from aemi; MacFS keeps assembly for its format-specific kernel

## Context

ADR-0011 kept hand-written arm64 assembly where it measured ahead of the same algorithm in intrinsics. MacFS's CRC-32C, bit count
and UTF-16 narrowing are not about file systems, so they were promoted into aemi (its ADR 0020) as C intrinsics with scalar
references, runtime dispatch and sanitized checks on macOS, x86-64 under Rosetta and arm64 Linux. Roadmap 0030 asked whether the
assembly still earned its place once aemi had them; roadmap 0029 asked for the published hybrid.

## Decision

FSCore's `CRC32C`, `BitCount` and `UTF16Name` call `AemiKernels`. `CFSKernels` keeps what is MacFS's own: the NTFS fixups in
assembly, with its portable C version as the reference, and the device ioctls. The rule of ADR-0011 stands and now points the other
way: aemi's kernels measure level with or ahead of the assembly, so the assembly goes. It stays, renamed `base_*_asm` and without
its unreachable three-stream tiers, in the dev-only benchmark baseline, so every later aemi change is measured against it.

The improvements went to aemi, where every consumer gets them: SHA3 `eor3` joins the fold's products (the assembly had the fused
pairs that clang's schedule lost), the CRC feature check is compile-time where the target guarantees it, short CRC inputs take one
`crc32cw`/`ch`/`cb` step each and are inlined, UTF-16 ends on a four-unit word step, and from 4 KiB three `crc32cx` streams run beside
the vector folds (roadmap 0029, aemi diary 2026-10-30-03).

## Evidence (Apple M2 Pro, release, median of nine, `fskbench`)

| Case | former assembly | aemi |
|---|---:|---:|
| CRC, one 4 KiB block in cache | 67.0 GB/s | 86.3 |
| CRC, one 64 KiB block in cache | 64.9 | 88.1 |
| CRC, 64 MiB / 4 KiB / 16 KiB blocks from DRAM | 58.4 / 56.2 / 58.3 | 58.7 / 55.4 / 58.2 (the memory's limit) |
| CRC, 12 / 64 / 256-byte pieces | 5.91 / 13.8 / 45.7 | 5.14 / 14.8 / 47.3 |
| Bit count, 64 MiB | 60.2 | 61.0 |
| UTF-16 narrowing, long / 12-unit / 30-unit names | 22.8 / 6.74 / 10.5 | 35.4 / 8.97 / 14.4 |

The one case the assembly still wins, 12-byte CRCs, is the Swift-to-C call every aemi facade pays (0.3 ns a name). In a reader the
change is within noise: `fsprobe` on `ntfs.img` (305 nodes, 5 ms a walk) read 2.7 to 3.6 GB/s before and 3.5 to 3.6 after.

Tests: the wrappers against independent Swift references (bitwise CRC at lengths to 16,384 around the 4 KiB chunks,
`nonzeroBitCount`), the fixups against the C reference with the record flush against an inaccessible page at either edge
(`GuardedBytes`, promoted from this repository to aemi's AemiTestKit, its ADR 0021). Mutants: the CRC wrapper shortening long inputs
(24 failures), the bit count dropping odd bytes (101), the UTF-16 wrapper returning a half-narrowed name (2), the fixups kernel without
its array bounds check (a crash on the guard page; it survived until the test made a header with the right count and the array
past the end).

## Consequences

A kernel that is not about a file system goes to aemi first, measured against the baseline here. The 12-byte CRC gap would close only
with an inlinable facade, which aemi's `internal import` of its C module does not allow; not worth a design change at 0.3 ns.
