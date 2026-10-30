# NEON kernels: derivation, measurement, state of the art (2026-10-30)

## CRC-32C fold

Reflected arithmetic: a 32-bit value `v` stands for V(x) = Σ v_i x^(31-i); `crc32cx(c, d)` computes (C·x^64 + D·x^32) mod P. The
carry-less product of two reflected 32-bit values, read as a reflected 64-bit value, is x·A·B, so `crc32cx(0, pmull(a, k))` is
A·K·x^33 mod P. With K = x^(8n-33) mod P that is A·x^(8n): a CRC shifted past n bytes. Hence, for three blocks of K bytes,
crc(c, A‖B‖C) = shift(crc(c, A), 2K) ^ shift(crc(0, B), K) ^ crc(0, C).

Constants (Python, then checked by a bitwise CRC over random data): K = 1024 → `0xa51b6135`, `0x170076fa`; K = 256 → `0xdd7e3b0c`,
`0xb9e02b86`. Kernel tests compare every length 0 to 1100 and the tier boundaries with the bitwise C reference.

## Measurements (`MACFS_DEV=1 swift run -c release fskbench`, 64 MiB, nine runs, median, this machine)

| Case | serial C | three-stream C | asm |
|---|---:|---:|---:|
| one buffer | 8.6 | 24.3 | 24.6 |
| 4 KiB blocks | 8.9 | 17.7 | 23.4 |
| 16 KiB blocks | 8.6 | 22.4 | 24.3 |

Bit count 21.0 (C) against 60.0 (asm). UTF-16LE to ASCII 3.9 (C loop) against 22.5 (asm). Results were checked equal before timing.

**Reading.** The three-stream fold triples serial throughput, and assembly equals intrinsics on one large buffer: the code generation is
not where the gain is. The 4 KiB gain is the 768-byte tier, which the C baseline lacks. Bit count and UTF-16 narrowing gain from
whole-vector reductions (`uaddlv`, `umaxv`) that the compiler did not produce from the scalar loops.

## State of the art (reported, not reproduced)

corsix/fast-crc32 (README, fetched 2026-10-30): on Apple M1, PMULL folding with twelve vector accumulators (dougallj) reaches 77.55 GB/s
and a fused vector-plus-scalar scheme (`v9s3x2e_s3`, EOR3) 85.05 GB/s; Chromium's three-stream scalar code is 25 GB/s, the class of this
kernel. Roadmap 0011 targets the fused scheme with the 4 KiB case first-class.

## The eight-lane fold (roadmap 0011)

Reflected 128-bit accumulators, lane 0 holding the first eight bytes. The carry-less product of two 64-bit lanes, read as a reflected
128-bit value, is x·A·B, so folding a lane forward by D bytes multiplies by x^(8D+63) for lane 0 and x^(8D-1) for lane 1; with the
constant held in the low 32 bits of a lane those become x^(8D+31) and x^(8D-33) mod P. D = 128: `0x6992cea2`, `0x0d3b6092`; D = 16:
`0xf20c0dfe`, `0x493c7d27`. The whole algorithm (eight accumulators, initial CRC in the first lane, merge, two `crc32cx`, scalar tail)
was checked in Python against the bitwise CRC before any assembly.

| Case (M2 Pro) | three streams, C | eight-lane fold, C intrinsics | eight-lane fold, asm (`eor`) | with `eor3` |
|---|---:|---:|---:|---:|
| 64 MiB | 24.7 | 52.1 | 58.7 | 59.3 |
| 4 KiB blocks | 17.9 | 50.4 | 56.8 | 58.5 |

## Candidates measured and not taken (roadmap 0012)

An LZ77 match copy (`docs/research/probes/lz-match-copy.c.txt`): 16-byte vector stores when the distance is 16 or more, otherwise a
16-byte pattern rotated by one `tbl` per store. Correct against the byte loop for every distance 1 to 40 and length 0 to 100 at a guard
page. On LZO it moved nothing (1110 to 1122 MB/s in three variants): matches are a few bytes, and the call costs what the vector saves.

## Later the same day: in aemi, and past the published numbers (ADR-0012)

The kernels moved to aemi as C intrinsics (aemi ADR 0020; its diaries 2026-10-30-02 and -03 hold the probes). What it took to
match and then pass the assembly, each measured:

- **`eor3`.** Clang's schedule split the pairs Apple cores fuse (`pmull2 acc` then `eor acc, acc, ...`); SHA3's `veor3q_u64` joins
  both products and the block in one instruction: 52 to 59 GB/s on 64 MiB. In the assembly it gives nothing: it had the pairs.
- **59 GB/s is the memory, not the kernel.** One block in cache folds at 67 to 70 GB/s; from DRAM every variant meets 59.
- **The hybrid** (roadmap 0029, corsix's `v9s3x2e` idea): three `crc32cx` streams beside the eight folds in a 4 KiB chunk
  [V | S0 | S1 | S2], each region shifted into place by the identity above with K = x^(8n-33) mod P for n = 384, 768, 1152.
  Each chunk starts from seed 0 and the running value is shifted past it by n = 4096, so chunks overlap: 86 to 90 GB/s in cache.
  Chunks of 16 or 64 KiB, whose regions lie kilobytes apart, fell to 38 and 43 from DRAM.
- **Short inputs** pay calls, not arithmetic: a compile-time feature check and an inlined tail of one `crc32cw`/`ch`/`cb` each.

| (GB/s, M2 Pro) | former assembly | aemi |
|---|---:|---:|
| one 4 KiB block, in cache | 67.0 | 86.3 |
| one 64 KiB block, in cache | 64.9 | 88.1 |
| 64 MiB from DRAM | 58.4 | 58.7 |
| 12 / 64 / 256-byte pieces | 5.91 / 13.8 / 45.7 | 5.14 / 14.8 / 47.3 |
| UTF-16 narrowing, long / 12-unit names | 22.8 / 6.74 | 35.4 / 8.97 |

corsix reports 77 to 85 on M1, a different core: the numbers are not a comparison of code.
