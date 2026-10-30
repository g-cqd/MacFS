# Btrfs

| Reference | How |
|---|---|
| btrfs-progs v6.14 (`btrfs restore -m -S -x`) | `BtrfsConformanceTests`: 6 images (plain, zlib, LZO, zstd, xxHash checksums, a subvolume), every node: type, mode, uid, gid, size, mtime, content. Link counts and directory sizes belong to the restored copy, not to Btrfs, so not compared; the kernel's Btrfs driver is absent here |
| liblzo2 2.10 | `LZO1XTests`: 96 streams from `lzo1x_1` and `lzo1x_999` decode to their originals; mutated streams agree with the byte-wise decoder; hand-built streams at the word-copy edges; input and output against guard pages |
| zstd 1.5.7 (RFC 8878; the CLI, `tests/golden-decompression*`, `tests/decodecorpus.c`, libzstd's `ZSTD_decompress`) | `ZstdTests`: 113 CLI frames (levels 1 to 22, checksum, no content size, block-size edges, two frames), 1,000 decodecorpus frames, the golden files; 2,400 damaged frames and 87,008 single-bit flips get libzstd's one-shot verdict and output; hand-built frames for checks no corpus reaches; under ASan and UBSan. Raw and RLE blocks are held to the capacity, not to the window, as libzstd holds them |
| zlib (RFC 1950/1951), `fs/btrfs/zlib.c` | Header checked, raw DEFLATE through libz, trailer not read, as Linux does |
| btrfs-progs v6.14 `tests/` | `ReferenceSuiteTests`: 136 images, none trap or hang; 77 read whole (fsprobe). 22 more stop at a data checksum: all are `btrfs-image` dumps, which keep metadata only, so their data was never there, and Linux refuses them the same way (98 read whole before data checksums, roadmap 0015, were verified). The rest are refused by name: corrupt or unsupported metadata, of which 12 are not recognized as Btrfs at all |

Data checksums are verified as Linux verifies them (roadmap 0015): `BtrfsDataChecksumTests` changes one data byte in the plain,
xxHash, zlib and LZO images. Not done: several devices (0020). One fuzz image
(`bko-200403`) declares a file of enormous size that is nearly all hole: reading it whole takes minutes of zero-filling, which
is correct and bounded by the walk's budget in the tests.
