# Working in MacFS

Foreign file systems (Btrfs, NTFS, ext2/3/4) on macOS, read-only. **Read [`docs/WHITE-PAPER.md`](docs/WHITE-PAPER.md) first.** This file
records what an agent cannot derive from the source: commands, gates, traps and the state of the work.

## Commands

```sh
swift package --package-path Packages/Tooling --disable-sandbox images            # test images + manifests (Apple container)
swift test --package-path Packages/FSCore                                         # readers, kernels, MountKit (needs the images)
swift test --package-path Packages/Tooling                                        # tooling, documentation law, source structure
swift package --package-path Packages/Tooling --disable-sandbox gates [--dry-run] # every static gate (see below)
swift package --package-path Packages/Tooling --disable-sandbox plists [--check]  # FSKit Info.plists from DiskFormat
swift package --package-path Packages/FSCore --disable-sandbox --allow-writing-to-package-directory format   # Aemi's formatter
MACFS_DEV=1 swift run --package-path Packages/FSCore -c release fskbench            # kernels against C baselines
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
- **`swift test` on the images takes the debug build**: `#filePath` locates `TestImages/`; run `images` first.

## State

Done: kernels, Btrfs, NTFS and ext readers, `Formats`, `MountKit`, FSKit modules (built, unsigned), the app (built, not launched),
tooling and gates. Blocked: signing (roadmap 0006, needs the account owner). Next by value: 0007 (NFS proxy), 0011/0012 (kernels),
0015 (checksums), 0023 (fuzzing). Read each entry's `status:` and `blocked-by:` before starting it.
