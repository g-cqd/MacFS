# XFS

| Reference | How |
|---|---|
| Linux 6.18 XFS driver, xfsprogs 6.14 | `XFSImageTests`: 2 images (4 KiB blocks; 1 KiB blocks with 8 KiB directory blocks), written by the kernel's own driver, every node against the manifest and against the kernel's view (`.reference`: type, mode, uid, gid, link count, size, directory size, mtime, ctime, content). `xfs_repair -n` finds each image clean |
| "XFS Algorithms & Data Structures", `fs/xfs/libxfs/xfs_format.h`, `xfs_da_format.h` | `XFSStructureTests`: extent records at their widest fields, shortform directories with 64-bit inode numbers (built bytes); an inode recording another number, extents out of order (inodes rewritten with a valid checksum); unwritten extents over stale random data written beneath the file system; creation times and allocated sizes |
| v5 metadata checksums (CRC-32C, stored little-endian) | `XFSChecksumTests`: one changed byte in the superblock, an inode, a data-fork B+tree block, a directory data block or a remote symlink block is a `checksum` error |

The images hold every form, asserted by `theImagesHoldEveryForm`: shortform, block (`XDB3`), leaf and node directories (10,000
names), extent-list and B+tree data forks (a level-2 tree of 2,997 extents at 1 KiB), attribute forks that shrink the data fork,
inline and remote symlinks, unwritten extents. Features read: ftype, sparse inodes, bigtime, nrext64, reflink, rmapbt, finobt
(the defaults of mkfs.xfs 6.14), meta_uuid, exchange-range, parent pointers, metadir.

Implemented: superblock, inodes (v3) by AG/block/slot, data forks (local, extent list, B+tree), directories by their data
blocks (every form; lookup by scan of the cached listing, not by hash), symlinks (inline and remote), block maps for
kernel-offloaded I/O. Refused, by name: v4 volumes (deprecated, and this kernel is built without them, so there is no
reference), volumes that need repair, unknown incompatible features, realtime files. Not done: the log is not replayed (a volume
that needs recovery reads as of its checkpoint), hashed directory lookup, extended attributes.

Mutants: 47 over the reader, all killed but two the code made redundant (the directory leaf-offset filter, removed; the extent
sort, replaced by the order check).
