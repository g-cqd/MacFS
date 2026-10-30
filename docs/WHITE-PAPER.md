# MacFS — Project White Paper

The rules this project runs on. **Read this at the start of every iteration.** An iteration that cannot satisfy a rule stops and fixes
the rule, or asks to change it in writing. Principles live here, never a log: the log is the diary.

## What this is

Foreign file systems on macOS, natively: Btrfs, NTFS and ext2/3/4 today. One set of readers (`Packages/FSCore`) sits under several ways
of reaching Finder: FSKit modules (the native path, ADR-0005), loopback proxies through macOS's own network file system clients
(planned: NFS first, WebDAV as one option among others), and the app's own browser, which needs nothing installed. A kernel extension is
a researched and recorded alternative, not a shipped one.

It follows Everest's lesson (ADR-0001): a mount technology is a seam, and which one fits is a measurement, not a preference. Everest
supplies findings; its code is not trusted here until a probe in this repository confirms it.

## The evidence rule

Every claim is named, given a probe that could fail, run, and recorded in the diary before it is acted on.

- **A probe that cannot fail is not a probe.** An image whose files are all under 60 bytes cannot show that inline data past `i_block`
  is read (diary 2026-10-30-01). Before trusting a green run, ask what input would make it red.
- **A test that has never failed proves nothing.** Every test is seen red before it is seen green (TDD below); every gate is broken on
  purpose once (mutation below).
- **The oracle is never the author.** Expected trees come from the Linux tools that wrote the image (ADR-0007), checksums from published
  vectors, constants from a derivation checked by an independent implementation.
- **Unprobed claims are written as open questions, never as facts.** "Reported" for what another project measured; "not verified" for
  what this machine could not run (an FSKit mount needs a signed module, ADR-0006).

## Safety is the first goal

Order of goals: correctness, then safety, then speed. Speed never buys back either.

**Every byte on a disk is hostile.** A disk can come from anywhere. Every offset, length, count and pointer read from it is checked before
use: `DiskBytes` throws on any out-of-range load, arithmetic on disk values is checked (`AemiKernel`'s `checked*`), and no structure is
trusted because a parent pointed at it (a tree child must sit one level below its parent; a directory may not be entered twice).

**Read-only by construction.** No reader has a write path, every module mounts read-only and answers every mutation `EROFS`. Writes are a
separate roadmap item per format, each needing its own crash-consistency story (roadmap 0017).

**No recursion; every loop has a bound.** Tree depth, extent depth, index blocks and directory walks are on-disk data, so traversal uses
explicit stacks with a depth rule or a budget. A self-referencing structure ends in `DiskError.corrupt`, never in a stack overflow.

**`unsafe` is confined and netted.** The readers build under strict memory safety. Unsafe code is the kernels' C/assembly boundary and a
few buffer copies, each under a checked range. Results that come back from the kernels are checked by the Swift wrappers.

**Refuse what is not understood.** An unknown incompatible feature, a striped profile, an encrypted or compressed stream the reader cannot
decode: each is refused with `unsupported` or `accessDenied`, never read as if it were plain.

## Speed is a number

Every change that can affect performance is benchmarked before and after, release build, median and spread, against the fairest native
baseline available (`fskbench`; ADR-0003). Assembly is written only where a measurement against intrinsics shows it pays, and is held to
the same reference tests as everything else. "Fastest" is not a word this project uses: the CRC-32C kernel is a third of the published
state of the art (research 2026-10-30-neon-kernels), and the roadmap says so.

## Process

**Red first.** A test is written first and run against a stub that gives a wrong answer; it must fail for the right reason before the
implementation is written. Code written before its test (the first kernels and the Btrfs reader, diary 2026-10-30-01) was brought to
red retroactively by mutation, and that is recorded as such.

**Mutation against a green baseline.** Break the code the way the test is meant to catch, watch it fail, restore from a copy (never from
`git checkout`). A mutant that survives is a missing test: write it, see it kill the mutant, then restore.

**Gates, all strict** (`swift package --package-path Packages/Tooling --disable-sandbox gates`): swift-format, SwiftLint (metrics),
deadwood, dolly, arcleak, fcheck, modeler check, TLA+ models under TLC, Lean proofs, plus the repository rules (documentation law, one
type per file and 250 lines). A finding is fixed, or accepted where it is with a directive and a reason. Never silently.

**Atomic commits that say why.** Never mix a refactor and a behaviour change. A problem found on the way is a roadmap entry.

## Dependencies

Aemi first: `AemiKernel` (loads, checked arithmetic, XXH64), `AemiIO` (`PosixFile`), `AemiRegex` (the tooling's rules), Aemi's shared
format and lint plugins and configs. One Aemi pin across every package (ADR-0004). Apple frameworks where macOS owns the job: FSKit,
Compression (zlib), CryptoKit (SHA-256). Anything else is an ADR with the alternatives compared.

## Documentation law

Enforced by `RepositoryRulesTests` (Packages/Tooling).

| Path | Rule |
|---|---|
| `docs/WHITE-PAPER.md` | Principles, never a log. Capped at 200 lines. |
| `docs/DESIGN.md` | The architecture as built. |
| `docs/adr/NNNN-title.md` | One decision per file, `accepted` or `superseded`; a supersession names itself in both directions. |
| `docs/roadmap/NNNN-title.md` | One claimable unit of work with `status:` (open, in-progress, done) and `blocked-by:`. A blocker exists and is not done. |
| `docs/diary/YYYY-MM-DD-NN.md` | The working log and the probe ledger. 256 lines; roll over. |
| `docs/research/` | Dated notes with their probe sources. |
| `docs/models/` | Generated TLA+ models (modeler), checked by TLC. |
