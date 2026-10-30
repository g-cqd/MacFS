---
status: done
blocked-by: []
date: 2026-10-30
---

# 0012 — More assembly and NEON kernels for the tools

Investigate, measure, then build only what pays: batch checksum verification of whole tree nodes and data extents; `$UpCase` folding and
name comparison; directory-entry scanning (ext dirents, Btrfs dir items); xxHash64 lanes; the LZO and LZNT1 decoders' copy loops; the
analyzers' own hot loops (dolly's token hashing, AemiRegex scans) where a probe shows a gap over Swift SIMD.

## Done: measured, and the answers were algorithms

`fsprobe` (walk and read everything) on a 1 GiB corpus (`swift package images --bench`), profiled with `/usr/bin/sample`:

| Image | before | after | what moved it |
|---|---:|---:|---|
| Btrfs | 1368 MB/s | 3009 | binary search inside tree nodes (keys are sorted; the scan was linear) |
| Btrfs, LZO | 561 | 1106 | decoding into one preallocated buffer under a single buffer scope |
| Btrfs, zlib | 632 | 850 | the tree search (decompression is Apple's) |
| ext4 | 5300 | 5415 | nothing; reads are `pread`-bound |

A NEON LZ match copy (16-byte stores, a `tbl`-rotated pattern for short periods) was built red first, killed two mutants, and moved
nothing on LZO's short matches (1110 against 1120 MB/s): not taken. Its source and tests are in `docs/research/probes/lz-match-copy*`,
for zstd and LZNT1 (0013, 0014), whose matches are longer.
