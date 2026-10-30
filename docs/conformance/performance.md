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

## Mounted (FSKit), the end-to-end path

The same walk over a mounted volume (`mount -F`, signed modules from /Applications), against APFS and against Apple's own FSKit
module (exFAT, the same tree in a 2 GB image): the fair bound for a module, since every operation crosses from the kernel to the
extension. Median of five, warm.

| | APFS | Apple exFAT (FSKit) | ext4 | NTFS | Btrfs |
|---|---:|---:|---:|---:|---:|
| large files (MB/s) | 16,608 | 15,634 | 14,574 | 14,406 | 13,623 |
| 20,000 small files (nodes/s) | 77,625 | 72,277 | 68,261 | 54,169 | 48,691 |

**Below the baseline when mounted**: 87 to 93% of Apple's module on data, 67 to 94% on small files. The readers themselves are
above it (tables above); the difference is the mount path. Apple's module lets the kernel read file blocks itself (FSKit's
kernel-offloaded I/O), which MacFS's modules do not yet: roadmap 0018, now the first lever. For small files, the Btrfs module pays a
tree lookup for each attribute request.

With kernel-offloaded I/O (roadmap 0018), the same mounts read large files at 14,538 (ext4), 15,824 (NTFS) and 15,860 (Btrfs)
MB/s: 93 to 101% of Apple's exFAT module. Small files are unchanged (68,908, 54,460, 48,902 nodes/s): the cost there is FSKit's
per-item lookup and attributes, not data, and remains below Apple's module (72,277).

NTFS LZNT1 (roadmap 0014; docs/research/2026-10-30-compression-kernels.md): text 3,340 MB/s, incompressible 13,400 MB/s through
the reader; the arm64 kernel alone decodes 4,170 MB/s, 3 times its C version at -O3. There is no system LZNT1 codec on macOS to
hold it to; ntfs-3g's decoder is byte-wise, as the C reference is.

Btrfs LZO through the arm64 LZO1X kernel: text 2,725 MB/s (1,764 with the Swift decoder; liblzo2 decodes 2,261 on the same
segments, the kernel alone 3,475).
