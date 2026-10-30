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

## Next, by the same method

- **LZO1X (Btrfs)**: the Swift decoder reads 1,764 MB/s end to end; liblzo2 decodes 2,240 on the same segments. Its token loop
  has the same shape (a state machine per instruction byte, short matches): the same three moves should apply.
- **zlib (Btrfs)**: the system libz inflates at 1,428 MB/s, the reader 1,147. Inflate is Huffman decoding, latency-bound on the
  bit buffer; the known arm64 gains (Chromium's `inflate_fast` with 16-byte chunk copies and a 64-bit bit buffer) are a larger
  kernel. Measure the reader's 20% first.
- **zstd (roadmap 0013)**: not read yet; a kernel would start from the reference decoder's FSE/Huffman loops.
