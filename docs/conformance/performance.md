# Performance against the baseline

The baseline is macOS reading the same tree from its own file system: `fsprobe --tree BenchImages/tree` walks it with
`opendir`/`readdir`/`lstat` and reads every file in 1 MiB pieces, the readers' own workload. Both warm, median of seven, Apple
M2 Pro. Compressed data is held to its codec instead: a reader cannot decode faster than the codec it calls.

| (MB/s; small: nodes/s) | native (APFS) | ext4 | NTFS | Btrfs | Btrfs zlib | Btrfs LZO |
|---|---:|---:|---:|---:|---:|---:|
| large files, compressible | 16,481 | 15,746 | 16,876 | 16,295 | 1,263 | 1,830 |
| large files, random | 16,374 | 16,021 | 15,815 | 15,764 | 16,486 | 15,523 |
| 20,000 small files (nodes/s) | 77,146 | 602,417 | 373,797 | 196,434 | 198,970 | 199,809 |

Codec bounds, same data in the same pieces: zlib 1,416 MB/s through MacFS's `fsk_inflate`, 1,291 through the system libz at
Btrfs's default level 3 (724 through Compression.framework, which the reader used before: 592 MB/s then; levels 6 and 9 favour
libz by 9 to 10% on text, docs/research/2026-10-30-compression-kernels.md); liblzo2 `lzo1x_decompress_safe` 2,240 MB/s on 4 KiB segments (the reader: 851 before).

Btrfs verifies its data checksums (roadmap 0015) on a piece's first read and remembers it: `fsprobe --keep` (one file system across
rounds, as a mounted volume) reads plain Btrfs at 15,592 and 16,607 MB/s; a first read, which checks every sector, at about
11,000. Small files: about 300,000 nodes/s, since `read` stopped looking up a file's parent on every piece.

How it got there (diary 2026-10-30-11): one copy per read instead of four (`ReadAssembly`, `BlockSource.read(at:into:)`: 10 to
16 GB/s); libz instead of Compression.framework (592 to 1,168), then MacFS's own inflate (1,160 to 1,263, diary 2026-10-30-20); an LZO decoder over pointers with word copies, and segments
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

Btrfs zstd (roadmap 0013): text 1,217 MB/s through the reader (1,202 with the C sequence loop). The decoder alone, with its
sequence loop in arm64 assembly, decodes the bench text in 128 KiB level-3 frames at 1,275 MB/s and source code at 1,500;
libzstd 1.5.7 decodes 1,110 and 1,300 (the C loop 1,253 and 933).

XFS (roadmap 0031; bench image written by the kernel): large files 14,769 MB/s (text) and 15,282 (random), small files 619,105
nodes/s; ext4 on the same tree 14,973, 15,792 and 678,394.

XFS lookups (roadmap 0037; `fsprobe IMAGE --lookups DIR`, release, every name of the directory once a round from a cold file
system, lookups/s; the base is the scan of a cached listing, commit 2950722):

| Image: directory | Form | Scan | Hashed | First lookup, scan → hashed |
|---|---|---|---|---|
| xfs: many (10,000) | node | 152,600 | 1.7–2.0 M | 414 → 10–28 µs |
| xfs: forty | block | 2.46 M | 2.3–2.8 M | 7.3 → 2.4–3 µs |
| xfs-hash: leaf (270) | leaf | 2.85 M | 2.6–2.9 M | 16 → 4–6 µs |
| xfs-hash: deep (225,000) | node, level 2 | 7,621 | 530,000–600,000 | 10.3 ms → 35–45 µs |
| xfs-hash-1k: deep (2,700) | node | 616,500 | 2.0–2.1 M | 137 → 8–11 µs |
| xfs-hash: collide (1,080 of one hash) | node | 1.08 M | 75,000–79,000 | 66 → 24–41 µs |

`collide` is the known regression: each lookup reads the data entries of the whole run of its hash, as the kernel does (about
24 ns a candidate); a real directory has runs of one or two. `BoundedCache` is `@inlinable`: unspecialized, each of a lookup's
three cache reads looked its dictionary's generic metadata up at run time, which halved the hashed figures above. Ranges are
rounds of the same run (±10%); the first round is the coldest. The xfs-hash directories hold 11 more names since the base
was measured (one-byte and dot-led ones). The test for "." and ".." compares bytes: two array literals built on each lookup
cost forty 15%.

NFS proxy (roadmap 0038; `macfs-nfsd`, release, mounted by `mount_nfs` on loopback; a fresh mount and server per measure so the
client's caches are cold, the image in the page cache; `cat` of the 10 × 20 MB files of `random/` and of `text/` in the bench
images, MB/s; harness `/tmp/xh/nfsbench.sh`). Calls answered in order, as before, against concurrently, eight at a time:

| Image | Server | rsize 32 KiB (client default): random, text | rsize 128 KiB: random, text |
|---|---|---|---|
| btrfs-plain | in order | 787–813, 762–870 | 1,290–1,429, 1,333–1,535 |
| btrfs-plain | concurrent | 576–627, 557–592 | 1,026 (misses made eight times) → 1,550–1,562, 1,568–1,579 |
| btrfs-zstd | in order | 766–830, 470–504 | 1,227–1,587, 681–735 |
| btrfs-zstd | concurrent | 576–645, 605–640 | 1,070 (misses made eight times) → 1,439–1,600, 1,546–1,568 |
| ext4 | in order | 830–1,015, 629–912 | 1,198–1,786, 1,216–1,795 |
| ext4 | concurrent | 855–885, 876–901 | 1,515–1,770, 1,525–1,810 |

The read size is the larger win: 128 KiB, the proxy's FSINFO preference, is now in the mount command. Concurrency first lost a
fifth on Btrfs: eight READs of one MiB each verified the whole MiB's checksums, because `BoundedCache.value` made a missing value
outside its lock in every caller. Concurrent misses of one key now wait for one make (Everest's in-flight fetches; a test reads
8.4 MB to verify one MiB before, under 2 MB after). Then concurrency is level on ext4 and plain Btrfs and doubles compressed text
(zstd decoding runs in parallel). The machine moved by about 10% between sessions: compare within a row. A `find` of the 20,134
entries took 0.15 to 0.23 s throughout.
