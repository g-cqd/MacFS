---
status: accepted
date: 2026-10-30
---

# 0007 — Test images come from the reference tools, and their manifest is the oracle

## Decision

`swift package images` runs `Scripts/make-test-images.inner.sh` in a pinned Alpine container: `mkfs.btrfs` (plain, zlib, lzo, zstd,
xxhash, subvolume), `mke2fs -d` then `e2fsck -fD` (ext2 with 1 KiB blocks, ext3, ext4, inline data, bigalloc), `mkntfs` and `ntfscp`. The
same script writes a manifest of every path, type, size and SHA-256 from the Linux side. Reader tests walk the whole tree and compare.
Each image also has a test proving it exercises the layout it exists for (compressed extents present, htree present, inline data past 60
bytes): an image that does not cannot fail for that reason.

## Consequences

Images are not committed (1.5 GB, sparse). The trees are built in the container's own `/tmp`: a shared directory collected Finder's
`.DS_Store` files during a run (diary 2026-10-30-01).
