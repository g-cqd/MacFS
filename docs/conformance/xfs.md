# XFS

| Reference | How |
|---|---|
| Linux 6.18 XFS driver, xfsprogs 6.14 | `XFSImageTests`: 2 images (4 KiB blocks; 1 KiB blocks with 8 KiB directory blocks), written by the kernel's own driver, every node against the manifest and against the kernel's view (`.reference`: type, mode, uid, gid, link count, size, directory size, mtime, ctime, content). `xfs_repair -n` finds each image clean |
| "XFS Algorithms & Data Structures", `fs/xfs/libxfs/xfs_format.h`, `xfs_da_format.h` | `XFSStructureTests`: extent records at their widest fields, shortform directories with 64-bit inode numbers (built bytes); an inode recording another number, extents out of order (inodes rewritten with a valid checksum); unwritten extents over stale random data written beneath the file system; creation times and allocated sizes |
| xfsprogs 6.14 `xfs_db hash`, Linux 6.18 directory code (`xfs_dir2_format`, `xfs_da3_node_lookup_int`, `xfs_da3_path_shift`) | `XFSHashedLookupTests`: `xfs_da_hashname` against xfs_db for 91 names; two images (`xfs-hash`, `xfs-hash-1k`) written by the kernel, holding block, leaf with stale entries, node and level-2 node directories and 1,080 names of one hash across leaves (`Scripts/xfs-names.c`), every name the kernel made found with its inode (227,423 and 5,393, `.names`), names absent (suffixed, of the same hash, removed) not found, every directory of the tree images agreeing with its listing; one-byte and dot-led names (`...`, `.a`, `..a`) in block, leaf and node directories, "." and ".." absent; a lookup reads at most 4 directory blocks and builds no listing, and a miss stops at the leaf where its hash's run ends; a leaf directory of one data block (xfs-1k's `dir/sub`, as large as a block directory) |
| v5 metadata checksums (CRC-32C, stored little-endian) | `XFSChecksumTests`: one changed byte in the superblock, an inode, a data-fork B+tree block, a directory data block or a remote symlink block is a `checksum` error; in `XFSHashedLookupTests`, a da node or leaf block too, and a da block of another directory or another kind is `corrupt` |

The images hold every form, asserted by `theImagesHoldEveryForm`: shortform, block (`XDB3`), leaf and node directories (10,000
names), extent-list and B+tree data forks (a level-2 tree of 2,997 extents at 1 KiB), attribute forks that shrink the data fork,
inline and remote symlinks, unwritten extents. Features read: ftype, sparse inodes, bigtime, nrext64, reflink, rmapbt, finobt
(the defaults of mkfs.xfs 6.14), meta_uuid, exchange-range, parent pointers, metadir.

Implemented: superblock, inodes (v3) by AG/block/slot, data forks (local, extent list, B+tree), directories by their data
blocks (every form), hashed lookup (roadmap 0037: the leaf's hash entries, the node tree, the next leaf while a hash run goes on), symlinks (inline and remote), block maps for
kernel-offloaded I/O. Refused, by name: v4 volumes (deprecated, and this kernel is built without them, so there is no
reference), ASCII case-insensitive volumes (`-n version=ci`: deprecated, and this kernel refuses to mount them), volumes that need repair, unknown incompatible features, realtime files. Not done: the log is not replayed (a volume
that needs recovery reads as of its checkpoint), extended attributes; the da blocks' `blkno` and uuid, and the leaf's hash order, are not checked. "." and ".." are not entries of a hashed lookup, as of the listing (the kernel resolves them before a lookup).
Damage tests (`XFSHashedLookupDamageTests`) change one block, its checksum recomputed, for each check of the lookup.

Mutants: about 35 distinct over the reader, all killed but two the code made redundant (the directory leaf-offset filter, removed; the extent
sort, replaced by the order check). Hashed lookup: 330 mutants (the hash, the lookup, the entries' end of a
block directory, the case-insensitive refusal), 23 that do not build, 299 killed; the 8 that survive are equivalent: a bound
of an even quantity moved by one across parity (three), a byte offset that is a multiple of 8 compared with 63 (two), the
size of the file type byte when there is none (two: v5 always has ftype, mkfs refuses `ftype=0` with CRCs), and a run that
"goes on" past the tree's last leaf, after which nothing comes. A first run, before the damage tests, left 49.
