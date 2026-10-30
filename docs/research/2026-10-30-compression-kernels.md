# Compression kernels in assembly: where the time goes

Question (user, 2026-10-30): implement the compression algorithms as assembly kernels and observe where they can be sped up.

Method: profile the reader first (`sample` on `fsprobe --under text`), then time the kernel alone on the real data
(the bench volume's 3,405 LZNT1 units, 89 MB in, 223 MB out, dumped once) against its portable C version at -O3, with every
unit checked byte for byte against the C one before timing. Apple M2 Pro, best of seven.

## LZNT1 (NTFS, roadmap 0014)

The token mix decides everything: 26.5 M literals and 26.0 M phrases for 223 MB, one token per 4.3 bytes; 95.5% of phrases are
16 bytes or shorter and 16 or more back, 4.5% are 8 to 15 back, none longer than 16; literals and phrases alternate (98% of
tokens switch kind). The cost is per token, not per byte.

| Step | Kernel MB/s | Why |
|---|---:|---|
| Swift, array-indexed (first version) | ~800 | 92% of the reader's time in the decode loop |
| C reference, byte-wise, -O3 | 1,381 | the test reference |
| arm64: split from `clz`, 8-literal groups as one word, word copies | 2,434 | fewer instructions per phrase |
| + literal runs by `rbit`+`clz`, phrases ≤16 as one 16-byte move | 2,373 | **no gain**: alternating tokens leave runs of one; the limit was latency, not instruction count |
| + the offset/length split kept in registers per band of positions | 2,950 | the split depends on the output position, so each phrase waited on `clz` of the cursor; it changes at most 8 times a chunk. `out += length` is now a one-cycle chain |
| + fast groups: bounds checked once per eight tokens | 4,170 | about 45 instructions per literal+phrase pair down to about 25 |

Reader end to end (fsprobe, text): 727 MB/s first, 3,340 now; stored units (incompressible) 7,164 first, 13,400 now (one copy,
straight from the volume). The rest of the gap to the kernel is the stored clusters gathered into an array before decoding.

Proof obligations, all tests: hand-built chunks for each rule (LZNT1Tests), every real unit and 7,200 damaged ones and 3,000
arbitrary inputs decode identically in the kernel and the C reference (LZNT1KernelTests), inputs and outputs flush against
guard pages (GuardPageTests: the overrunning moves stop inside the chunk), and 28 mutants of the kernel, 26 killed and 2
equivalent (a band boundary one position early only recomputes the same split).

## LZO1X (Btrfs)

Data: the bench text in 4 KiB segments compressed by liblzo2's `lzo1x_1` (as mkfs.btrfs writes them), 12,700 segments, 52 MB
out. Mix: 99.9% of instructions are M2 matches (3 to 8 bytes, mean 6.9, 98% at least 16 back), each followed by 0 to 3
literals (one, 88% of the time); literal runs are rare. The cost is per instruction.

| Step | MB/s | Why |
|---|---:|---|
| liblzo2 `lzo1x_decompress_safe` (gcc -O2, Linux VM, same machine) | 2,261 | the codec bound used so far |
| C reference (the Swift decoder ported byte for byte), clang -O3 | 2,740 | clang does as well as a first kernel |
| arm64, the reference's structure with 16- and 8-byte copies as subroutines | 2,740 | **no gain**: calls, rechecked bounds and the dispatch dominate |
| + M2 inline: 8 bytes of input and 16 of room checked once, one 8-byte and one 4-byte move | 3,475 | about 10 cycles an instruction down to 8 |

Reader end to end (fsprobe, text): 1,764 MB/s with the Swift decoder, 2,725 with the kernel (+55%), above liblzo2's bare rate.
What is left is the format's own chain: the next instruction's position depends on this one's literal count, a byte load away.

Tests: liblzo2's streams decode to their originals and to the C reference; damaged, cut and too-small-room streams and
arbitrary bytes give the same result and bytes in both, also flush against guard pages; built M2 streams at every distance to
20, ending exactly at the capacity or overflowing it. 18 mutants of the kernel: 17 killed, 1 equivalent (the bound on an
extended length's zero bytes: without it the input still runs out, and the result is the same refusal).

## Next, by the same method

- **zlib (Btrfs)**: the system libz inflates at 1,428 MB/s, the reader 1,147. Inflate is Huffman decoding, latency-bound on the
  bit buffer; the known arm64 gains (Chromium's `inflate_fast` with 16-byte chunk copies and a 64-bit bit buffer) are a larger
  kernel. Measure the reader's 20% first.
- **zstd (roadmap 0013)**: not read yet; a kernel would start from the reference decoder's FSE/Huffman loops.
