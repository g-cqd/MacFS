---
status: done
blocked-by: []
date: 2026-10-30
---

# 0025 — The mount check as a tested plugin

Today the end-to-end check (attach, `mount -F`, walk, compare with the manifest, write refused, unmount, detach) is a probe script.
Make it `swift package mounts [--dry-run]` in Tooling: the plan tested with the recording runner, the comparison shared with
`ImageOracle`, run in the gates when the modules are enabled.

## Done

`swift package --package-path Packages/Tooling --disable-sandbox mounts [--dry-run]`: twelve test images attached, mounted
through their modules, compared with their manifests by `TreeComparison` (FileManager's view, as Cocoa apps see the volume),
refused a write, unmounted and detached, the volume released whatever failed. The sequence is tested on the recording runner,
the comparison on a real directory, the system runner's capture with one real process. Not in the gates: it needs the app
installed with its modules enabled. ext4-gpt (two devices on attach) and btrfs-zstd (0013) are left out.
