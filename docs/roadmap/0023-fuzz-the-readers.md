---
status: open
blocked-by: []
date: 2026-10-30
---

# 0023 — Fuzz the readers

Mutated images and random structures against every reader, with AemiTestKit's fuzz helpers: no crash, no hang, only `DiskError`.

## Progress

The reference test suites cover the hostile half for ext and Btrfs (docs/conformance): 190 e2fsprogs images and 136 btrfs-progs
images, among them its fuzz-tests, run on every `swift test`; none traps or hangs, and the e2fsck-clean ones read whole. They found
`i_crtime` read from 128-byte inodes. The LZO decoder has its own mutation corpus against the decoder it replaced. Open: mutated
NTFS images (no reference suite exists), and seeded mutation of the test images with AemiTestKit's `ByteMutator`.
