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
