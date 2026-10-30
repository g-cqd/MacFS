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

## zstd (Btrfs, roadmap 0013)

Written in C from RFC 8878 (no zstd on macOS), then measured against libzstd 1.5.7 (Homebrew, the same version as the test
oracle) on the bench text and on source code, each cut in 128 KiB frames at level 3 as Btrfs writes them.

| Step | Text MB/s | Code MB/s | What |
|---|---:|---:|---|
| libzstd 1.5.7 | 1,110 | 1,310 | the bound |
| first correct version | 388 | 350 | `back_read` 28% (not inlined; bit by bit at every stream's end), one Huffman symbol at a time 22%, `memcpy` calls 22% |
| inlined reads, an 8-byte load at the stream's end, 4 Huffman streams in lockstep, 16-byte moves | 962 | 757 | |
| a 64-bit container with reloads everywhere | 846 | 823 | faster for Huffman, **slower** for sequences: the reload's load sits on the chain from one sequence to the next |
| the container for Huffman, the bit position for sequences | 1,028 | 805 | |
| sequence cells carrying base value and extra bits | 1,042 | 898 | no side tables per sequence. Reading the three fields (or states) in one read measured **slower** (951 / 716) |
| zero-bit reads skip the load (their early return had been lost) | 1,220 | 862 | most literal and match codes have no extra bits |
| the first 16 bytes of a match or a literal run copied unconditionally | 1,236 | 933 | trip counts stop mispredicting; 32 bytes cost text 10% |

Then the build: SwiftPM and Xcode compile release C at -Os, which cost 8 to 11%; CFSKernels asks for -O3. Through the reader,
Btrfs zstd text reads at 1,202 MB/s (1,035 at -Os).

Correctness held throughout: the CLI's frames, the golden files, 1,000 decodecorpus frames, libzstd's one-shot verdicts on 2,400
damaged frames and 87,008 single-bit flips, all under ASan and UBSan with one workspace reused across frames (stale tables).
Mutants: about 70 over the decoder. Killed by the verdicts, the sanitizers or hand-built frames, except those that are
equivalent (a check a later one subsumes: the FSE count sum and the spread's end, the early declared-size refusal, the
single-segment window, literals overrunning their buffer, one of two weight-count guards) and one unreached: a compressed block
larger than its window whose output fits, which needs an encoder to build. Three checks proved redundant and were removed.

### The sequence loop in arm64 (kernels_zstd_arm64.S)

Literals and tables stay in C; the loop that decodes and executes the sequences, where the code frames spend their time, is
assembly, called once a block when the stream holds 8 bytes or more. Same frames, `/usr/bin/time -l` cycle counts less those
of a build that skips sequences, divided by the 79.5 M sequences of the text:

| Step | Text MB/s | Code MB/s | What |
|---|---:|---:|---|
| C loop (above) | 1,253 | 933 | |
| first arm64 version | 1,154 | 1,419 | each field its own read and refill: one chain of shifts per field |
| one read of the three fields' bits, and a refill branch instead of a clamp | 1,275 | 1,500 | the cells say `width` (state bits + extra bits) first: their sum gives the bits a sequence takes, one refill, the fields cut from one window word by shifts reckoned modulo 64. The stream's start test is a branch predicted taken; as a `csel` it sat on the chain |
| libzstd 1.5.7 | 1,110 | 1,300 | |

About 14.7 cycles a sequence to decode (11.9 without the state chain), 17.6 with execution. What the M2 charges: a shifted
operand adds a cycle (2 for `add x, x, y, lsr #n`), so does a `cmp`+`csel` pair on the chain; `lslv`, `ubfx` and an extended
add cost 1. The window holds 57 to 64 unread bits: a sequence of more than 57 (long fields and rare codes together) takes a
slower path that reads in two parts (`Lzs_wide`). Execution checks room once (`literals + match + 16`) and the offset as
`offset - 1 < produced` unsigned, which refuses 0 too; within 16 bytes of the end a careful path copies exactly. Matches 1 to 15
back expand by a TBL pattern and its stride.

The C loop keeps its old cell layout off arm64: the `width` layout cost it a fifth (933 to 851 code). `zstd.c` has both under
`#if defined(__aarch64__)`, asserts the offsets the assembly reads, and keeps the C loop as the reference
(`fsk_ref_zstd_decompress_frame`). The x86_64 build (Rosetta, against Homebrew's x86 libzstd) decodes the same as libzstd.

Through the reader, Btrfs zstd text: 1,217 MB/s (1,202 before): text is mostly literals, as the frames' 2% shows; the gain is
on sequence-dense data.

Tests (ZstdKernelTests, kernel against the C loop): every CLI fixture, decodecorpus and golden frame, damaged frames, every bit
flip of the flips corpus, cut frames and too little room, all with the same result, consumed length and bytes; output and input
flush against guard pages; a libzstd frame of sequences wider than 57 bits that are not their block's last, some in cells whose
states start above 0 (`Scripts/zstd-wide.c`, `ZSTD_compressSequences`, built in the container; no CLI frame has one); hand-built
blocks for single checks: a stream ending in a zero byte, an offset one past the output in the fast and the careful path,
literals past those decoded, a stream read 50 KB below its start. KernelABITests calls each assembly kernel (the zstd loop,
LZO1X, LZNT1, the fixups) with every callee-saved register (x19 to x29, sp, d8 to d15) set to a value of its own and checks them
after: a kernel that restores the wrong pair passes every result test. ASan and UBSan over all of it.

58 mutants of the kernel, run in a C harness (the same corpora, about 2 s): 51 killed there, 1 by KernelABITests (x25 and x26
not restored), 6 equivalent: baseline width 15 instead of 16 (baselines are below 512), slack 15 instead of 16 twice (the 16-byte
moves fit either way), two pattern bytes past the stride (rewritten before they are read), and the fast path's literal check,
which the block's 128 KiB output cap and the literals buffer's slack make unreachable before the trailing check refuses. Two
checks proved redundant, and went: rep[0] - 1 = 0 for the repeat code 3 (the offset check refuses it) and the careful path's
separate offset-0 test.

## DEFLATE (Btrfs zlib): MacFS's own inflate (inflate_kernel.c)

The reader called the system libz (1.2.12). It now calls `fsk_inflate`, a decoder of its own in C, and libz became the tests'
oracle (`fsk_oracle_inflate` in CodecOracle; CFSKernels no longer links libz). The bench: the text tree (222.6 MB) in 128 KiB
pieces, as Btrfs compresses them, raw DEFLATE from libz's deflate, each piece checked against libz before timing. MB/s, ours /
libz, best of seven:

| data | level 1 | level 3 (Btrfs's default) | level 6 | level 9 |
|---|---:|---:|---:|---:|
| text (`BenchImages/tree/text`) | 1,440 / 1,286 | 1,416 / 1,291 | 1,595 / 1,748 | 1,748 / 1,948 |
| C source (2.6 MB) | 1,084 / 1,006 | 1,216 / 1,151 | 1,170 / 1,117 | 1,170 / 1,120 |
| small files concatenated | 994 / 917 | | 1,160 / 1,129 | |
| executables (6.6 MB) | 805 / 766 | | 888 / 831 | |

Through the reader, Btrfs zlib text: 1,263 MB/s (1,160 with libz, same session).

What decided it:

- **Entries that consume a symbol whole.** One 32-bit entry per index of the next 11 (literal/length) or 8 (distance) bits, a
  second level for longer codes (inftrees.c's sizing). The entry holds the bits the code *and its extra bits* take, so one shift
  consumes a length or a distance; the extra value is `(saved & mask(total)) >> code_length`.
- **The next entry read before the refill and before the copy.** After a refill all 64 bits of the buffer are input (the
  refill is `bits |= load64(in) << (count & 63); in += (~count & 63) >> 3; count |= 56`), and one symbol takes at most 48 bits
  (15 + 5 + 15 + 13). So the next literal/length entry can be read from the bits that remain, before the refill and before the
  match copy, which then overlap the chain of table reads. This moved text from 1,206 to 1,416 MB/s; nothing else came close.
- **One test for what is rare**: a second level, the end of block and a refused code share a branch.
- `count -= e` subtracts the whole entry; only its low byte (the bits' count) is read, which saves a mask per symbol.

What did not help, measured and removed:

- **Pairs of literals in one entry**: no gain.
- **Three literals per refill**: no gain on any data.
- **Root widths** 10 to 12 and 8 to 10: within 1%.
- **Loop alignment** 16 to 64: within 1%.

Removing the match copy altogether (wrong output, timing only) gained 2 to 3%. The loop is bound by the dependent chain of
table load, shift and next load, which hand-written arm64 would not shorten, so it stays C (-O3). Where libz stays ahead, text
at levels 6 and 9 by 9 to 10%, literals and matches alternate (26 M each per 222 MB at level 9, every match 16 bytes or
shorter). The gap is open.

Conformance (InflateTests, against libz's one-shot verdict, bytes and length):

- libz's streams at every level, strategy, window and memory level, into four capacities each;
- zlib 1.2.12's own inflate coverage vectors (test/infcover.c);
- every bit flip and every cut of six small streams, and 3,000 arbitrary block bodies;
- 50 hand-built streams (`fsk_oracle_vector`, CodecOracle) for rules libz's encoder never writes:
  - blocks after sync, full, partial and Z_BLOCK flushes;
  - a non-empty stored block between fast-path blocks;
  - codes without distances, lone 1-bit codes and codes one 15-bit code short, read where unused;
  - 31 distance or 287/288 length codes, all 316 code lengths;
  - an all-zero precode, no end-of-block code;
  - headers ending exactly at the input's end;
  - distance codes 30 and 31 in the fast path;
  - a full output before an error, and before a distance too far back;
  - 48-bit symbols at every bit alignment;
  - 20 random complete codes up to 15 bits;
- input and output flush against guard pages;
- all of it under ASan and UBSan.

The table sizes are zlib's `enough` maxima: 2,340 entries for 286 symbols at root 11, and 400 for 30 at root 8. The decoder
reserves 2,342 and 402.

900 mutants of the decoder in a C harness (the same corpora; `/tmp`, not kept): 796 killed, 24 did not compile, and 80
survive. All 80 were judged equivalent:

- array sizes and root widths;
- unread entry fields and verdict values only tested for truth;
- copy thresholds and fast-path margins (274 is the tight one);
- the fixed tables' cache;
- second-level sizing: larger levels decode the same while the tables fit;
- the stored header's 31 or 32 bits, with a byte-aligned count;
- the 8-byte load read as 7: the loop's second refill ORs real input over the missing byte before it is read.

The hand-built streams went in when 117 had survived. 23 of those were real gaps and are killed now; the 14 others were
mutants of four checks that proved redundant and were removed: count[0] in the canonical codes, clearing the precode's lengths, `*produced = 0` up front, and
a 4 GiB limit that only copied libz's `uInt`.

## Next, by the same method

- **XFS hashed directory lookup**: done (roadmap 0037). A lookup in 225,000 names went from 7,600 to 600,000 a second; Swift,
  not assembly, as the cost is the blocks reached, not the instructions.
- **zstd (roadmap 0013)**: the sequences are in assembly (above); literals' Huffman streams are the next cost on text.
