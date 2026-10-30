# ext2, ext3, ext4

| Reference | How |
|---|---|
| Linux 6.18 ext4 driver | `ExtConformanceTests`: 9 images (ext2, ext3, ext4, inline data, bigalloc, a UUID-derived checksum seed, meta_bg, a volume the kernel grew into meta_bg and filled itself, GPT), every node: type, mode, uid, gid, link count, size, directory size, mtime, ctime, content. The kernel also writes nanosecond times (and so inode checksums) into each image after mke2fs, so time decoding meets the kernel's encoding |
| `fs/ext4/*.c` checksum functions | `ExtChecksumTests`: one changed byte per structure is a `checksum` error; 11 mutants killed |
| e2fsprogs v1.47.2 `tests/f_*` | `ReferenceSuiteTests`: 190 images, none trap or hang; the 16 e2fsck finds clean read whole. 111 of 190 read whole (fsprobe) |
| e2fsprogs `debugfs dx_hash` | `ExtHtreeTests`: 900 directory hashes (legacy, half-MD4, TEA, signed and unsigned; names of 1 to 70 bytes and non-ASCII; two seeds) |
| `fs/ext4/namei.c` `dx_probe`, `ext4_htree_next_block`; `super.c` `descriptor_loc` | `ExtHtreeTests`, `ExtDescriptorLayoutTests`: every name of every indexed directory (one with two index levels, 10,000 names) found through its index; a collision split across leaves; each bad-index case the kernel falls back from; 38 mutants, 35 killed |

Implemented: superblock, group descriptors (32/64 bytes, flex_bg), inodes (128 bytes and larger, extra fields, nanosecond times,
creation time where `i_extra_isize` covers it), extent trees (unwritten extents as holes), indirect blocks, inline data, linear
and htree directories (listed linearly, looked up by hash through the index), meta_bg (descriptors per metagroup, from
`s_first_meta_bg` on, after a superblock backup where the group has one), symlinks (fast and slow), metadata checksums
(superblock, descriptors, inodes, extent blocks, directory leaves and htree index blocks' `dx_tail`). Refused, by name:
compression, external journal devices, dirdata, fscrypt contents. Not done: journal replay (a volume that needs recovery reads as
of its checkpoint); casefolded directories are matched exactly and scanned, not hashed.

Lookup in an indexed directory reads its index and one leaf: in dir/sub (13 blocks) a hit reads at most 6 blocks including the
inode and extent block, a miss at most 2 more. A directory already listed answers from its listing. Survivors among the mutants,
all equivalent in result: a binary search with `>=` (a name on a leaf boundary lands one leaf early and the continuation check
carries it on), skipping the cached listing (the block cache already holds those blocks; it costs a hash and a CRC, not I/O),
and the end-of-directory hash fix-up (it needs a name hashing to exactly 0xFFFFFFFE).

Found in the reference tools: `mke2fs -d` (e2fsprogs 1.47.2) with `inline_data` writes a file whose tail is a hole (100,000
bytes of data, size 300,000) with the size of its last data block (100,352); the kernel reads it so, and so does MacFS. The test
tree keeps such a file for NTFS only.

Found by the references: a root the kernel makes from a full linear directory block keeps that block's old checksum tail in
`dt_reserved`, so its last 12 bytes look like a leaf's tail; the reader took it for one and refused a valid directory (a
kernel-filled image, roadmap 0016). Blocks are told apart by position, as the kernel does. `f_bigalloc_symlink_with_xattr`: a
fast symlink's xattr block counts a whole cluster in `i_blocks` (the reader subtracted a block). `i_crtime` was read from
128-byte inodes (24 e2fsprogs images); e2fsck's "exit status 0" includes
checksum-only repairs, so "clean" is its expected output, not its exit status.
