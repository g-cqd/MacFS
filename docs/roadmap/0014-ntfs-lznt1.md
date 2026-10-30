---
status: open
blocked-by: []
date: 2026-10-30
---

# 0014 — LZNT1-compressed NTFS streams

Decode compression units; needs an image written by Windows or ntfs-3g with compression on.

Unblocked: ntfs-3g writes LZNT1-compressed files through FUSE (`-o compression`, and the compressed attribute on a directory), and
FUSE works in the container with `--cap-add ALL` (diary 2026-10-30-11). ntfs-3g is then also the reference that reads them back.
