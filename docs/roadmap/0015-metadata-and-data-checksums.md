---
status: open
blocked-by: []
date: 2026-10-30
---

# 0015 — Checksums everywhere they exist

ext4 inode, extent, directory and group descriptor checksums; Btrfs data checksums from the csum tree. Batched through the CRC kernel.

## Progress

ext4, done: with `metadata_csum`, group descriptors, inodes (16 or 32 bits), extent blocks and directory blocks are verified as
Linux's `ext4_*_csum` compute them; a plain directory block without its tail is refused, as Linux does; htree nodes (`dx_tail`)
are left to 0016. The oracle is every ext4 image the Linux tools wrote, read in full, plus one changed byte per structure
(`ExtChecksumTests`). Two images were added so each path meets a real disk: `big/islands.bin` (twelve extents, so an external
extent block) and `ext4-uuid-seed` (the seed derived from the UUID; the others store it). Eleven mutants, each killed; two
survived until those images and a test of the inode checksum's high half existed. fsprobe on the 1 GiB ext4 bench image: 5.28 GB/s
before, 5.28 to 5.34 after, once the inode checksum became one CRC call over a stack copy (diary 2026-10-30-10).

Open: Btrfs data checksums from the csum tree.
