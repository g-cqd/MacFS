# Promoting MacFS's kernels and technologies to aemi (2026-10-30)

**Sources.** `Packages/FSCore` (`CFSKernels`, `FSCore`, `Tests/KernelABI`, `Tests/CodecOracle`), the mutation harnesses (/tmp),
aemi at `2fbe4e4` (`~/Developer/g-cqd/aemi`, Aemi-Studio/aemi): its ADRs 0008, 0011, 0018, 0020 and 0021, `Sources/CAemiKernels`,
`AemiKernel`, `AemiTestKit`, `AemiIO`, `AemiRuntime`, `scripts/`. MacFS ADR-0003, 0011, 0012 (ADR-0004 for the pin).

## What has gone already

aemi's ADR 0020: MacFS's CRC-32C, bit count and UTF-16LE narrowing became `CAemiKernels` C intrinsics with scalar references, runtime
dispatch and sanitized checks on arm64, x86-64 under Rosetta and arm64 Linux. MacFS consumes them (ADR-0012). aemi's ADR 0021 took
the guard-page tests (`GuardedBytes`), which MacFS's `GuardPageTests` use. The precedent sets the procedure: an aemi ADR, tests seen
failing in aemi first, aemi's bench at `-Os`, its sanitized check scripts, then MacFS pins the revision and deletes its copy.

## The obstacle: aemi has no assembly

Every aemi kernel is C with intrinsics (aemi ADR 0020: "C intrinsics, like every aemi kernel"); there is no `.S` file. MacFS keeps
hand-written arm64 assembly where it measures ahead of intrinsics (ADR-0011's rule): the zstd sequence loop, LZO1X, LZNT1 and the NTFS
fixups. Promoting any of them first needs an aemi ADR that admits assembly on MacFS's terms: a portable C twin compiled everywhere as
the oracle and the non-arm64 path, a measured win over the same algorithm in intrinsics at `-Os`, the callee-saved-register check
(MacFS's `KernelABI`), the guard-page suite, and ASan/UBSan runs of the C twin. Without that ADR, only the C versions can move, and the
assembly stays in MacFS calling into aemi's C for the rest.

## Candidates

| # | What (MacFS) | Generality: other users in the family | aemi home | Condition | Verdict |
|---|---|---|---|---|---|
| 1 | `BoundedCache`, now coalescing concurrent misses (a Btrfs MiB verified once, not eight times) | Any cache read by threads: deadwood's and dolly's per-file tables, HTTP servers | `AemiRuntime` | Swift, inlinable (specialization measured: XFS lookups halved without it); its deadlock rule documented | **First**: no policy question, measured |
| 2 | `fsk_inflate` (DEFLATE/zlib, C, 413 lines), libz as its test oracle | gzip and zlib in HTTP (g-cqd/HTTP), PNG, zip | new `CAemiCodecs` + `AemiCodecs` | Behind libz at levels 6 and 9 on text: closed or recorded; streams over 4 GiB tested | Second |
| 3 | zstd frame decoder (C, 743 lines) and its arm64 sequence loop | HTTP `zstd` content coding, `.zst` archives, SquashFS and EROFS (roadmap 0032) | `AemiCodecs` | The aemi assembly ADR for the loop; until then the C path alone | Third |
| 4 | LZO1X decoder (assembly, C twin) | Btrfs, SquashFS (0032), kernel images | `AemiCodecs` | As 3 | With 3 |
| 5 | `fsk_xxh64` (C, inside the zstd decoder) | zstd frames; aemi has a Swift `XXH64` in `AemiKernel` | `CAemiKernels`, beside the CRC | One implementation for C and Swift callers, measured against the Swift one | Moves with 3 |
| 6 | `KernelABI` (callee-saved registers checked around every assembly call) | Any assembly in aemi: the prerequisite of 3 and 4 | `AemiTestKit` (C and arm64 assembly) | — | With the assembly ADR |
| 7 | `DiskBytes` (bounds-checked big- and little-endian loads; aemi's loads check only in debug) | Every binary parser over hostile bytes: AemiProtobuf, image and archive readers | `AemiKernel` `CheckedBytes` | Same speed as today's wrapper in a release build | Fourth |
| 8 | `AlignedReader` (sector-aligned reads of raw devices; its arithmetic proved in Lean) | Any raw-device or uncached reader | `AemiIO`, beside `PosixFile` | The Lean proof stays in MacFS, pointing at aemi's code, or aemi adopts Lean | Later |
| 9 | Mutation testing (Python harnesses in /tmp, four sharded clones, line ranges) | Every package that applies red TDD; four MacFS steps used it | An aemi command plugin, `mutate`, tested like MacFS's plugins (ADR-0008) | Swift, no Python (the owner's rule); clones and sharding as measured here | Fifth; removes "harnesses live in /tmp" |
| 10 | LZNT1 (assembly) | Windows formats only (NTFS, `RtlDecompressBuffer` data) | `AemiCodecs` | As 3 | Only if a second user appears |
| 11 | XDR and ONC RPC records, `LoopbackServer` with limits | NFS only | — | — | Stays: protocol-specific |
| 12 | NTFS fixups (assembly), device ioctls, the readers, `MountedTree` | File systems only | — | — | Stay (ADR-0012) |
| — | `Hex`, `SortedSearch`, `CountingSource` | aemi has `Hex`; the rest is trivial or test-only | — | — | Not promoted |

## Order and what each step proves

1. `BoundedCache` to `AemiRuntime`: aemi tests red first (eight concurrent misses make once; a failed make leaves the key to the next
   caller), MacFS pins and deletes its copy, the XFS lookup and NFS benchmarks rerun unchanged.
2. The codecs as C (`AemiCodecs`): inflate, then zstd and LZO1X with their C twins; libz and the zstd CLI's frames as oracles, the
   guard-page suite, aemi's sanitized scripts natively and under Rosetta; MacFS's tests then run against aemi's codecs.
3. The aemi assembly ADR with `KernelABI` in AemiTestKit, then the zstd and LZO1X loops, each kept only if aemi's bench measures it
   ahead of the C at `-Os`.
4. `CheckedBytes` takes the checked endian loads; `DiskBytes` becomes a typealias or goes.
5. The `mutate` plugin, then MacFS's harnesses deleted.

## Risks

- One aemi pin across every MacFS package (ADR-0004): each promotion moves the pin for FSCore and Tooling together, and AemiJSON and
  AemiRegex pin aemi too, so a promotion can wait on their bumps.
- A new codecs module grows aemi's surface; aemi's own white paper decides whether codecs belong there or in a sibling package with the
  same rules.
- Moving code must not cost speed: every step reruns MacFS's benchmarks (performance.md) before the copy is deleted.
