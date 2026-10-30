# Performance against the baseline

The baseline is macOS reading the same tree from its own file system: `fsprobe --tree BenchImages/tree` walks it with
`opendir`/`readdir`/`lstat` and reads every file in 1 MiB pieces, the readers' own workload. Both warm, median of seven, Apple
M2 Pro. Compressed data is held to its codec instead: a reader cannot decode faster than the codec it calls.

| (MB/s; small: nodes/s) | native (APFS) | ext4 | NTFS | Btrfs | Btrfs zlib | Btrfs LZO |
|---|---:|---:|---:|---:|---:|---:|
| large files, compressible | 16,481 | 15,746 | 16,876 | 16,295 | 1,168 | 1,830 |
| large files, random | 16,374 | 16,021 | 15,815 | 15,764 | 16,486 | 15,523 |
| 20,000 small files (nodes/s) | 77,146 | 602,417 | 373,797 | 196,434 | 198,970 | 199,809 |

Codec bounds, same data in the same pieces: zlib 1,428 MB/s through the system libz (724 through Compression.framework, which
the reader used before: 592 MB/s then); liblzo2 `lzo1x_decompress_safe` 2,240 MB/s on 4 KiB segments (the reader: 851 before).

Btrfs verifies its data checksums (roadmap 0015) on a piece's first read and remembers it: `fsprobe --keep` (one file system across
rounds, as a mounted volume) reads plain Btrfs at 15,592 and 16,607 MB/s; a first read, which checks every sector, at about
11,000. Small files: about 300,000 nodes/s, since `read` stopped looking up a file's parent on every piece.

How it got there (diary 2026-10-30-11): one copy per read instead of four (`ReadAssembly`, `BlockSource.read(at:into:)`: 10 to
16 GB/s); libz instead of Compression.framework (592 to 1,168); an LZO decoder over pointers with word copies, and segments
decoded in place (851 to 1,830). Large-file rates are within noise of native; small files read 2.5 to 8 times faster than
native, since a reader pays no system call per file. Compressed data reaches 82% of its codec's bare rate.
