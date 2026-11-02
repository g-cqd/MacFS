# Working in MacFS

Foreign file systems (Btrfs, NTFS, ext2/3/4, XFS) on macOS, read-only. **Read [`docs/WHITE-PAPER.md`](docs/WHITE-PAPER.md) first.** This file
records what an agent cannot derive from the source: commands, gates, traps and the state of the work.

## Commands

```sh
swift package --package-path Packages/Tooling --disable-sandbox images            # test images, manifests, reference manifests
swift package --package-path Packages/Tooling --disable-sandbox images --corpus   # e2fsprogs, btrfs-progs and zstd test suites (TestCorpus/)
swift package --package-path Packages/Tooling --disable-sandbox images --bench    # bench images and the native tree (BenchImages/)
swift run --package-path Packages/FSCore -c release fsprobe --tree BenchImages/tree # the native baseline; --under PATH for a reader
swift test --package-path Packages/FSCore                                         # readers, kernels, MountKit (needs the images)
swift test --package-path Packages/FSCore --sanitize=address --sanitize=undefined --filter 'Zstd|LZNT1|LZO1X|GuardPage|KernelABI|Inflate'  # C and asm kernels under ASan/UBSan (corpus needed)
swift test --package-path Packages/Tooling                                        # tooling, documentation law, source structure
swift package --package-path Packages/Tooling --disable-sandbox gates [--dry-run] # every static gate (see below)
swift package --package-path Packages/Tooling --disable-sandbox plists [--check]  # FSKit Info.plists from DiskFormat
swift package --package-path Packages/Tooling --disable-sandbox mounts [--dry-run] # every image through its installed module
swift package --package-path Packages/FSCore --disable-sandbox --allow-writing-to-package-directory format   # Aemi's formatter
MACFS_DEV=1 swift run --package-path Packages/FSCore -c release fskbench            # kernels against C baselines
swift run --package-path Packages/FSCore -c release macfs-nfsd TestImages/ext4.img    # NFS proxy; prints the mount command
swift run --package-path Packages/FSCore -c release macfs-nfsd TestImages/ext4.img --mount /tmp/m   # through the mount seam; Ctrl-C unmounts
swift run --package-path Packages/FSCore -c release macfs-nfsd --sweep    # settle what a dead process left (registry-cli.pb in Application Support)
# The agent (0039), live without the app: sign with the Developer ID identity, then launchctl bootstrap a plist naming a test
# --service and --registry (see docs/diary/2026-11-01-03.md); `macfs-agent call list|mount IMG DIR|unmount ID|sweep --service S`.
xcodegen generate && xcodebuild -scheme MacFS -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
swift test --package-path Packages/FSCore 2>&1 | swift run --package-path Packages/Tooling macfs-tool summary
```

`gates` first installs the analyzers `Scripts/analyzers.lock` pins (aemi's lock, copied; SHA-256 and `--version` checked) into
`~/Library/Caches/g-cqd-analyzers`, shared with aemi's `analyzers.sh`; `macfs-tool analyzers` installs only. `MACFS_<TOOL>` still
overrides a path (roadmap 0010). Lean
comes from elan (`~/.elan/bin/lake`), TLC from `~/.local/share/tla/tla2tools.jar`.

## Gates

swift-format (Aemi config, `--strict`), SwiftLint (Aemi metrics config), deadwood, dolly, arcleak (pinned as AemiRegex pins them), fcheck,
modeler `check`, modeler `tla` + TLC for `ReadOnlyModule`, `Browser`, `ExtensionStatus`, Lean (`Proofs/`), and in Tooling's tests the
documentation law and one type per file under 250 lines. Accept a finding where it is, with a reason: `// @dl:accept -- why` (dolly),
`// swiftlint:disable:next rule` with a comment.

## Traps

- **A green image test can be blind.** Each image needs a test that it exercises its layout; two did not at first (diary 2026-10-30-01).
- **Dependencies move together**: aemi in FSCore, AemiRegex (which pins aemi) in Tooling, `Scripts/analyzers.lock` and the style
  configs from the same aemi revision (ADR-0004). Check the heads' pins before bumping one.
- **Formatting moves dolly anchors.** After `format`, run `gates`: an accept directive must sit directly above the anchor line.
- **BSD `sed` has no `\b`** and fails silently; use `perl -pi -e`. Assert every scripted edit's anchor exists.
- **Mutation testing runs once a day, not after every slice** (the owner, 2026-11-01). Between runs, each change is still
  seen failing first (red, then green). The daily run covers the code changed since the last one; its survivors become tests
  or are written down as equivalent. Count a test binary that crashes as a kill (a non-zero exit), keep the harness's file
  variable local, and check after an interrupted run that no mutant is left in a source file.
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
- **`BoundedCache` must stay `@inlinable`**: across modules, an unspecialized generic looks its metadata up on every call, which
  halved XFS lookups. Inlinable code needs `public import` of what it names (InternalImportsByDefault).
- **An XFS directory's form is where its data fork ends** (`xfs_dir2_format`), not its size: a leaf directory of one data block is
  as large as a block directory (xfs-1k's `dir/sub`).
- **When dl-cdn.alpinelinux.org crawls** (apk hangs), pass a mirror:
  `swift package --package-path Packages/Tooling --disable-sandbox images --mirror ftp.halifax.rwth-aachen.de`.
- **A generic `some Collection` copy across modules is not specialized**: it went element by element (34 MB/s). Take concrete types.
- **e2fsck's "exit status 0" includes repairs**: a clean e2fsprogs image is one whose expected output is only the passes.
- **Install only after the Release build's exit status is 0**: Release turns some Debug warnings into errors, and a failed build
  leaves the previous one in the derived-data folder, ready to be installed by mistake.
- **Install with `swift package --package-path Packages/Tooling --disable-sandbox install --check`** (roadmap 0041). It refuses a
  failed build or a bad signature or entitlement, keeps the previous app in `/tmp/MacFS.app.previous`, and runs the mount check.
- **Every build's copy of the app gets registered, and its modules run instead of the installed ones**: pluginkit listed them at
  `/tmp/macfs-release/.../MacFS.app` (and at a scratch build's folder). The installer unregisters the build's copy and deletes it.
  Do not `pluginkit -r` and `-a` a module: that lost XFS's enablement, which only System Settings can give back.
- **A module enabled again in System Settings stays disabled to FSKit until its process restarts**:
  `pkill -9 -f XFSModule.appex`.
- **swiftly's proxy exports `TOOLCHAINS` and `SDKROOT` to `swift package` plugins**: xcodebuild then links the app with the
  open-source toolchain and fails. The installer runs it under `env -u TOOLCHAINS -u SDKROOT`.
- **Every command goes through `SystemCommands`** (swift-subprocess, ADR-0017): a deadline per call, process-group teardown, bounded
  output. Its `run` blocks, so it refuses a call from a task (status 127): call it from a thread (tests: `runOffThePool`).
  MountKit must not depend on it (the FSKit modules link MountKit). `macfs-tool` must stay free of `await`.
- **`lsregister -f` alone does not register the app's modules**; FSKit then drops them from its enabled list, which only System
  Settings restores. Register with `lsregister -f -R -trusted`, before unregistering any other copy. `pluginkit -a` dropped one.
- **Write tests judge with each format's own checker** (ADR-0018), in a container image built once:
  `container build -t macfs-checkers:2 -f Scripts/checkers/Containerfile Scripts/checkers`. Without it, those tests are skipped.
- **No container left running when nothing uses it** (the owner's rule). `Checkers` starts the container system when a test needs
  it and stops it when the test process exits, if it started it; runs are `--rm`, one at a time, through `SystemCommandRunner`.
  After building an image, `container builder stop` and `container system stop`; after an interrupted run,
  `container list --all` and remove what is left.
- **After a restart**, the agent path of `macfs-tool mounts` failed until `MacFS.app/Contents/MacOS/MacFS --register-agent`
  (the agent was "enabled" but not reachable). The mount check's last case writes (`WriteCheck`) and needs the checkers' image.
- **Writable FSKit mounts** (roadmap 0046): asked by name, `mount -F -t ext4 -o rw /dev/diskN point`, or Disk Arbitration's
  mount argument `writable` (it drops a bare `rw`); anything else is read-only, automounts included. Disk Arbitration runs the
  module's check (`fsck_fskit -t <type> -q|-y`) before every mount of a writable device; the first mount after an install may
  be refused with 0xf8da000c (a stale FSKit connection): retry.
  Writes go through the kernel-offloaded block map, never FSKit's write handler for mappable files: through it, a write of 256
  KiB or more never reached the module and left the writer stuck in the kernel (state `U`) until a restart. Never read
  `completeIO`'s `status` (a null `any Error`; reading it crashed the module). A second image with the same volume UUID as one
  still attached will not mount ("a file with the same name already exists"): give a copy its own `s_uuid`. The `dd` on PATH is
  GNU's (`bs=1M`); `/bin/dd` takes `bs=1m`.
- **macOS 27 mounts NTFS disks with its own reader** (`UVFSService`, `ntfs.fs`), not ours; ours (`ntfsro`) runs when named.
- **`diskutil` cannot unmount or mount our FSKit volumes** (StorageKit error 119; it shows "no file system"), while Disk
  Arbitration's own calls and Finder's Eject can. Use `hdiutil detach`, `umount` or `DADiskUnmount`.
- **The first mount right after reinstalling may fail**: the module process is still starting. Run `mounts` again.
- **Offline `resize2fs` never makes meta_bg** (it moves blocks); the kernel's online resize does. `resize2fs` is in
  e2fsprogs-extra, and it does not grow an image file: truncate it first.
- **`set -e` does not stop inside an `&&` list**: `rm -rf tree && cp ...` failed silently when Finder wrote .DS_Store files
  into the shared directory; the bench script now swaps a finished copy in.
- **Kernels: profile, then time the kernel alone on real data against its C reference** (agreement checked first). A change
  that cuts instructions may gain nothing when the chain is latency (LZNT1's literal runs); guard-page tests are what catch
  an overrunning move, never output comparisons.
- **SwiftPM and Xcode compile release C at -Os**: CFSKernels asks for -O3 (8 to 11% on zstd). Measure kernels as they are built.
- **A decoder's error paths need the reference's verdict, not "no trap"**: TestCorpus/zstd holds libzstd's one-shot verdicts on
  damaged frames and every single-bit flip; the CLI's streaming decoder is not that oracle (it accepts a frame shorter than its
  declared size). Memory-safety checks need the sanitizers: a mutant that overruns the workspace still returns an error.
- **zsh: `rm -f *.zst` with no match aborts the whole command line**; `setopt nullglob` or quote it.
- **A new FSKit module mounts only once enabled**: `pluginkit -e use -i <bundle id>` marked XFSModule enabled, yet mounts said
  "disabled" until `fskit_agent` was restarted (`kill` it; launchd restarts it). Users enable it in System Settings.
- **XFS frees a deleted file's blocks in the background**: an allocation right after an `rm` does not reuse them. To put stale
  data under unwritten extents, the image script writes beneath the file system into those extents' blocks.
- **This container's kernel has no XFS v4** (`CONFIG_XFS_SUPPORT_V4` off): no reference for v4, so it is refused.
- **A dx root may end in a stale leaf tail** (`dt_reserved` is never cleared): tell directory blocks apart by position.
- **Python's byte paths hide normalization bugs**; Cocoa asks in NFD. Compare through `FileManager`, as `mounts` does.
- **`F_LOG2PHYS` is not a probe of FSKit's block maps** (ENOTSUP on Apple's modules too): stream the modules' debug log instead.
- **Assembly kernels owe their callers x19-x29, sp and d8-d15**: no result test sees a wrong restore. KernelABITests checks
  each kernel through `fsk_abi_call` (Tests/KernelABI); add a test there with every new kernel.
- **zstd's arm64 sequence loop needs frames no CLI writes**: sequences over 57 bits that are not their block's last come only
  from `Scripts/zstd-wide.c` (`ZSTD_compressSequences`, built by `images --corpus` into TestCorpus/zstd/wide).
- **libz is a tests-only oracle**: CFSKernels does not link it; CodecOracle (Tests/CodecOracle) does, for `fsk_oracle_inflate`,
  libz's deflate, and the hand-built DEFLATE streams `fsk_oracle_vector`. A rule libz's encoder never writes (lone codes, an
  all-zero precode, distance 30 in the fast path...) needs a vector there: libz's own streams left 23 real gaps in inflate.
- **One proxy serves one mount**: the export admits a single MNT (the mount table shows its path to everyone), so after `umount`
  start `macfs-nfsd` again; a second `mount_nfs` of a live one is "Permission denied" by design.
- **GNU coreutils come first on PATH**: `stat -f` is GNU's file-system mode there; use `/usr/bin/stat`, `/usr/bin/find`.
- **`umount` takes a path and removes whatever is mounted there**: unmount only after the table shows our `mountedFrom` at the
  point (TLC found the eject-then-remount trace). A pending record proves ownership by the backend's `claims`, nothing looser.
- **A sandboxed app may register only a sandboxed agent** (BTM: "SMAppService target executable must be sandboxed because the app
  is sandboxed"), and a sandboxed tool needs its Info.plist in the binary (`CREATE_INFOPLIST_SECTION_IN_BINARY`) or it traps at
  launch. A sandboxed agent can run `mount_nfs`.
- **`SMAppService.register` from a shell-launched app is "Operation not permitted"**: launch through `open -a MacFS --args ...`
  and read `/usr/bin/log show --predicate 'subsystem == "dev.gcqd.MacFS"'` (zsh's `log` is a reserved word).
- **Assigning a `RawSpan` into an `XPCDictionary` crashes the Swift 6.4 compiler**: `XPCDictionary.setBytes(_:for:)` uses the C API.
- **`open -W` does not reliably wait for an app that exits at once**: it returns 0 ("Unable to block on application") or fails
  with status 1 ("initial call to kevent() failed: No such process") while the app still runs. Scripted app commands write
  `--result FILE` atomically and the caller waits for the file (`AppLaunch`).
- **One owner per registry**: a sweep unmounts what its own process does not serve. The agent uses `registry.pb`,
  `macfs-nfsd --mount` uses `registry-cli.pb`.
- **The agent answers only binaries of team NP94WB3P75** (`isFromSameTeam`, both ways). The local Apple Development identities
  "cannot be used for signing code"; sign test binaries with the Developer ID identity. An unsigned or ad-hoc agent has no team,
  so every connection is interrupted.
- **Hand-written TLA+ goes in `Gates.specifications`**, beside the modeler-generated `modelledTypes`.
- **`BoundedCache.value(for:)` makes a missing key once**: concurrent callers wait for the maker, so a `make` must never wait on
  a key whose maker waits on its own.
- **`swift test` on the images takes the debug build**: `#filePath` locates `TestImages/`; run `images` first.

## State

Done: kernels, Btrfs, NTFS and ext readers, `Formats`, `MountKit`, signed FSKit modules that mount and automount (0005, 0006, 0024),
the NFS proxy (0007), tooling and gates, kernels from aemi at its state of the art (0011, 0012, 0029, 0030; ADR-0012), checksums
everywhere (0015), conformance against the reference implementations and suites (docs/conformance), readers at the native baseline,
and a Settings window with a tested status check. Mounted small files remain below Apple's own FSKit module (docs/conformance/performance.md).
Kernel-offloaded I/O (0018) brings mounted large files to Apple's own module. Names match as APFS matches them (0022);
`mounts` checks every image end to end (0025). ext looks names up by hash and reads meta_bg (0016).
NTFS reads LZNT1 and Btrfs LZO through arm64 kernels (0014), Btrfs zstd through a C decoder held to libzstd whose sequence loop
is arm64 assembly (0013; docs/research/2026-10-30-compression-kernels.md), Btrfs zlib through MacFS's own inflate held to
libz. XFS reads through its own module (0031) and looks names up by hash (0037). The NFS proxy mounts soft at a single-use secret
export, bounds its connections and answers a connection's calls concurrently (0038 in progress, ADR-0014); concurrent cache misses are
made once (`BoundedCache`). Everest's features are on the roadmap with their improvements (ADR-0016, 0035–0044, research
2026-10-30-everest-code-review); writes cover every format and mount path (0017, 0026–0028, 0045, 0046); promotion to aemi is
studied (0047). Next by value: the mount seam and registry (0035), then the agent (0039); on the codec side, zstd literals' Huffman
streams. Read each entry's `status:` and `blocked-by:` before starting it.
