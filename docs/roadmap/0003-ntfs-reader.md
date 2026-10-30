---
status: done
blocked-by: []
date: 2026-10-30
---

# 0003 — NTFS reader, read-only

## Done

Red first against a stub. Image with 300+ root names (INDX blocks), case-insensitive lookup through `$UpCase`, free space from
`$Bitmap`. Data-run vectors written after a mutation survived (no negative offsets in a fresh image).
