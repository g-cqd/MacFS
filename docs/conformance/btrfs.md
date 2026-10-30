# Btrfs

| Reference | How |
|---|---|
| btrfs-progs v6.14 (`btrfs restore -m -S -x`) | `BtrfsConformanceTests`: 5 images (plain, zlib, LZO, xxHash checksums, a subvolume), every node: type, mode, uid, gid, size, mtime, content. Link counts and directory sizes belong to the restored copy, not to Btrfs, so not compared; the kernel's Btrfs driver is absent here |
| liblzo2 2.10 | `LZO1XTests`: 96 streams from `lzo1x_1` and `lzo1x_999` decode to their originals; mutated streams agree with the byte-wise decoder; hand-built streams at the word-copy edges; input and output against guard pages |
| zlib (RFC 1950/1951), `fs/btrfs/zlib.c` | Header checked, raw DEFLATE through libz, trailer not read, as Linux does |
| btrfs-progs v6.14 `tests/` | `ReferenceSuiteTests`: 136 images, none trap or hang; 98 read whole (fsprobe) |

Not done: zstd (roadmap 0013), data checksums from the csum tree (0015), several devices (0020). One fuzz image
(`bko-200403`) declares a file of enormous size that is nearly all hole: reading it whole takes minutes of zero-filling, which
is correct and bounded by the walk's budget in the tests.
