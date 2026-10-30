# Working in MacFS

Foreign file systems (Btrfs, NTFS, ext2/3/4) on macOS, read-only. **Read [`docs/WHITE-PAPER.md`](docs/WHITE-PAPER.md) first.** This file
records what an agent cannot derive from the source: commands, gates, traps and the state of the work.

## Commands

```sh
swift package --package-path Packages/Tooling --disable-sandbox images            # test images, manifests, reference manifests
swift package --package-path Packages/Tooling --disable-sandbox images --corpus   # e2fsprogs and btrfs-progs test suites (TestCorpus/)
swift package --package-path Packages/Tooling --disable-sandbox images --bench    # bench images and the native tree (BenchImages/)
swift run --package-path Packages/FSCore -c release fsprobe --tree BenchImages/tree # the native baseline; --under PATH for a reader
swift test --package-path Packages/FSCore                                         # readers, kernels, MountKit (needs the images)
swift test --package-path Packages/Tooling                                        # tooling, documentation law, source structure
swift package --package-path Packages/Tooling --disable-sandbox gates [--dry-run] # every static gate (see below)
swift package --package-path Packages/Tooling --disable-sandbox plists [--check]  # FSKit Info.plists from DiskFormat
swift package --package-path Packages/Tooling --disable-sandbox mounts [--dry-run] # every image through its installed module
swift package --package-path Packages/FSCore --disable-sandbox --allow-writing-to-package-directory format   # Aemi's formatter
MACFS_DEV=1 swift run --package-path Packages/FSCore -c release fskbench            # kernels against C baselines
swift run --package-path Packages/FSCore -c release macfs-nfsd TestImages/ext4.img    # NFS proxy; prints the mount command
xcodegen generate && xcodebuild -scheme MacFS -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
swift test --package-path Packages/FSCore 2>&1 | swift run --package-path Packages/Tooling macfs-tool summary
```

`gates` needs fcheck and modeler, which have no releases yet: `MACFS_FCHECK=…/fcheck MACFS_MODELER=…/modeler` (roadmap 0010). Lean
comes from elan (`~/.elan/bin/lake`), TLC from `~/.local/share/tla/tla2tools.jar`.

## Gates

swift-format (Aemi config, `--strict`), SwiftLint (Aemi metrics config), deadwood, dolly, arcleak (pinned as AemiRegex pins them), fcheck,
modeler `check`, modeler `tla` + TLC for `ReadOnlyModule`, `Browser`, `ExtensionStatus`, Lean (`Proofs/`), and in Tooling's tests the
documentation law and one type per file under 250 lines. Accept a finding where it is, with a reason: `// @dl:accept -- why` (dolly),
`// swiftlint:disable:next rule` with a comment.

## Traps

- **A green image test can be blind.** Each image needs a test that it exercises its layout; two did not at first (diary 2026-10-30-01).
- **Formatting moves dolly anchors.** After `format`, run `gates`: an accept directive must sit directly above the anchor line.
- **BSD `sed` has no `\b`** and fails silently; use `perl -pi -e`. Assert every scripted edit's anchor exists.
- **Never `git checkout` a file to undo a mutation.** Copy first, restore the copy.
- **Shared directories collect `.DS_Store`.** Build anything that is hashed in the container's own `/tmp`.
- **After a failed `xcodebuild`, use a fresh `-derivedDataPath`**: a stale one embedded extensions without their Info.plist.
- **`FSError` is FSKit's.** The readers' error is `DiskError`.
- **One aemi revision everywhere** (ADR-0004): AemiRegex decides it; move FSCore with it.
- **In zsh, `log` is a builtin.** Use `/usr/bin/log show|stream`; the builtin swallows the arguments and prints nothing.
- **After reinstalling the app, kill the old module processes with SIGKILL**: they ignore SIGTERM and keep serving the old code.
- **`mke2fs -E offset=` zeroes the start of the image**: write a partition table after it. **`sgdisk -q` writes nothing** here.
- **`AEMI_DEV=1` rewrites aemi's `Package.resolved`.** Revert it before stashing or committing in aemi.
- **An aemi change reaches MacFS in order:** aemi `main`, then AemiRegex's pin (its tests), then FSCore and Tooling together. Measure
  an unpublished aemi with `MACFS_DEV=1 swift package edit aemi --path …`, and `unedit` before committing.
- **Gate an aemi kernel push on every check by exit status:** `swift test`, `scripts/checksum-kernels-check.sh` and its `--linux`
  run. The Linux path is built with other features than macOS's and broke once when only `swift test` gated (aemi diary 03).
- **A mutant that does not compile proves nothing**, and neither does one that changes speed but not output (a narrowing that stops
  early falls back to the transcoder): pick mutants the result can see.
- **At `-Os`, write SIMD accumulators out.** An array of them in a loop is not unrolled or kept in registers (aemi ADR 0020).
- **The container runs with `--cap-add ALL`** so the kernel can loop-mount ext images and ntfs-3g can use FUSE (`mknod /dev/fuse`).
- **`btrfs-image` is in `btrfs-progs-extra`** on Alpine, and `btrfs restore` has no `-q`.
- **A typed-throws closure passed to a `rethrows` API crashes Swift 6.4's SIL verifier** (`withUnsafeMutableBytes`): use an untyped one.
- **A generic `some Collection` copy across modules is not specialized**: it went element by element (34 MB/s). Take concrete types.
- **e2fsck's "exit status 0" includes repairs**: a clean e2fsprogs image is one whose expected output is only the passes.
- **Install only after the Release build's exit status is 0**: Release turns some Debug warnings into errors, and a failed build
  leaves the previous one in the derived-data folder, ready to be installed by mistake.
- **The first mount right after reinstalling may fail**: the module process is still starting. Run `mounts` again.
- **Offline `resize2fs` never makes meta_bg** (it moves blocks); the kernel's online resize does. `resize2fs` is in
  e2fsprogs-extra, and it does not grow an image file: truncate it first.
- **`set -e` does not stop inside an `&&` list**: `rm -rf tree && cp ...` failed silently when Finder wrote .DS_Store files
  into the shared directory; the bench script now swaps a finished copy in.
- **Kernels: profile, then time the kernel alone on real data against its C reference** (agreement checked first). A change
  that cuts instructions may gain nothing when the chain is latency (LZNT1's literal runs); guard-page tests are what catch
  an overrunning move, never output comparisons.
- **A dx root may end in a stale leaf tail** (`dt_reserved` is never cleared): tell directory blocks apart by position.
- **Python's byte paths hide normalization bugs**; Cocoa asks in NFD. Compare through `FileManager`, as `mounts` does.
- **`F_LOG2PHYS` is not a probe of FSKit's block maps** (ENOTSUP on Apple's modules too): stream the modules' debug log instead.
- **`swift test` on the images takes the debug build**: `#filePath` locates `TestImages/`; run `images` first.

## State

Done: kernels, Btrfs, NTFS and ext readers, `Formats`, `MountKit`, signed FSKit modules that mount and automount (0005, 0006, 0024),
the NFS proxy (0007), tooling and gates, kernels from aemi at its state of the art (0011, 0012, 0029, 0030; ADR-0012), checksums
everywhere (0015), conformance against the reference implementations and suites (docs/conformance), readers at the native baseline,
and a Settings window with a tested status check. Mounted small files remain below Apple's own FSKit module (docs/conformance/performance.md).
Kernel-offloaded I/O (0018) brings mounted large files to Apple's own module. Names match as APFS matches them (0022);
`mounts` checks every image end to end (0025). ext looks names up by hash and reads meta_bg (0016).
NTFS reads LZNT1 and Btrfs LZO through arm64 kernels (0014; docs/research/2026-10-30-compression-kernels.md).
Next by value: 0031 (XFS), 0013 (zstd), an inflate kernel (zlib is the system's libz today). Read each entry's `status:` and `blocked-by:` before starting it.
