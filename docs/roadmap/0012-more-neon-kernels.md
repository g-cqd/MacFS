---
status: open
blocked-by: []
date: 2026-10-30
---

# 0012 — More assembly and NEON kernels for the tools

Investigate, measure, then build only what pays: batch checksum verification of whole tree nodes and data extents; `$UpCase` folding and
name comparison; directory-entry scanning (ext dirents, Btrfs dir items); xxHash64 lanes; the LZO and LZNT1 decoders' copy loops; the
analyzers' own hot loops (dolly's token hashing, AemiRegex scans) where a probe shows a gap over Swift SIMD.
