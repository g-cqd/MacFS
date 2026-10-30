---
status: done
blocked-by: []
date: 2026-10-30
---

# 0001 — NEON kernels: CRC-32C, fixups, bit count, UTF-16

## Done

Assembly with a C reference and oracle tests (every length 0 to 1100, tier boundaries, misaligned starts, 2000 random fixup headers,
RFC 3720 vectors). Mutations of a fold constant (28 failures) and of the fixup store (1000) caught. Benchmarked (ADR-0003).
