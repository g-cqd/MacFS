# ext2, ext3, ext4

| Reference | How |
|---|---|
| Linux 6.18 ext4 driver | `ExtConformanceTests`: 7 images (ext2, ext3, ext4, inline data, bigalloc, a UUID-derived checksum seed, GPT), every node: type, mode, uid, gid, link count, size, directory size, mtime, ctime, content. The kernel also writes nanosecond times (and so inode checksums) into each image after mke2fs, so time decoding meets the kernel's encoding |
| `fs/ext4/*.c` checksum functions | `ExtChecksumTests`: one changed byte per structure is a `checksum` error; 11 mutants killed |
| e2fsprogs v1.47.2 `tests/f_*` | `ReferenceSuiteTests`: 190 images, none trap or hang; the 16 e2fsck finds clean read whole. 109 of 190 read whole (fsprobe) |

Implemented: superblock, group descriptors (32/64 bytes, flex_bg), inodes (128 bytes and larger, extra fields, nanosecond times,
creation time where `i_extra_isize` covers it), extent trees (unwritten extents as holes), indirect blocks, inline data, linear
and htree directories read linearly, symlinks (fast and slow), metadata checksums (superblock, descriptors, inodes, extent and
directory blocks). Refused, by name: meta_bg, compression, external journal devices, dirdata, fscrypt contents. Not done: htree
`dx_tail` checksums and hashed lookup (roadmap 0016), journal replay (a volume that needs recovery reads as of its checkpoint).

Found in the reference tools: `mke2fs -d` (e2fsprogs 1.47.2) with `inline_data` writes a file whose tail is a hole (100,000
bytes of data, size 300,000) with the size of its last data block (100,352); the kernel reads it so, and so does MacFS. The test
tree keeps such a file for NTFS only.

Found by the references: `i_crtime` was read from 128-byte inodes (24 e2fsprogs images); e2fsck's "exit status 0" includes
checksum-only repairs, so "clean" is its expected output, not its exit status.
