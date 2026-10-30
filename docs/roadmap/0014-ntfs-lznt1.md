---
status: done
blocked-by: []
date: 2026-10-30
---

# 0014 — LZNT1-compressed NTFS streams

Decode compression units; needs an image written by Windows or ntfs-3g with compression on.

Unblocked: ntfs-3g writes LZNT1-compressed files through FUSE (`-o compression`, and the compressed attribute on a directory), and
FUSE works in the container with `--cap-add ALL` (diary 2026-10-30-11). ntfs-3g is then also the reference that reads them back.

## Done

LZNT1 (`LZNT1.swift`, the `fsk_lznt1_decompress` kernel: arm64 assembly, portable C reference), compression units read as
ntfs-3g reads them (none allocated: zeros; all: stored as is; some: LZNT1), straight into the result. Compressed streams are never
block-mapped. Image `ntfs-lznt1` (the test tree written compressed by ntfs-3g) against its manifest and ntfs-3g's view; kernel
work and numbers in docs/research/2026-10-30-compression-kernels.md.
