---
status: open
blocked-by: []
date: 2026-10-30
---

# 0019 — Prove the CRC fold identity

`shift(v, n) = crc32cx(0, pmull(v, x^(8n-33) mod P))` over GF(2)[x], in Lean with Mathlib. Today it is derived and checked numerically.
