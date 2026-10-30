---
status: open
blocked-by: []
date: 2026-10-30
---

# 0018 — Kernel-offloaded I/O

FSKit's blockmap for uncompressed extents and runs, so the kernel reads data blocks itself (msdos ships with it on).

Measured need (docs/conformance/performance.md): mounted, the modules read large files at 87 to 93% of Apple's FSKit exFAT module,
which offloads; the readers alone are at native speed.
