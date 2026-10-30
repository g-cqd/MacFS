---
status: done
blocked-by: []
date: 2026-10-30
---

# 0005 — FSKit modules

## Done

Three signed modules (0006) on the macOS 27 `FSVolume.Handler` API, enabled by the owner in System Settings. Every test image was
attached with `hdiutil attach -nomount -readonly`, mounted as the user with `mount -F -t btrfs|ext4|ntfsro -o rdonly`, and walked through
the kernel against its Linux-side manifest (probe: `docs/research/probes/mount-compare.py.txt`): eleven images, 315 or 305 entries each,
0 differences. `touch` answers "Read-only file system"; a zstd extent answers "Operation not supported"; NTFS opens `HELLO.TXT` as
`hello.txt` and lists no system files; `df` reports the volume sizes. Automatic mounting is not done (0024).
