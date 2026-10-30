---
status: accepted
date: 2026-10-30
---

# 0006 — One FSKit module per format, read-only, with names that shadow nothing

## Decision

- One module per format (`BtrfsFS`, `NTFSFS`, `ExtFSModule`), all code shared; the format is the only difference.
- Short names `btrfs`, `ext4`, `ntfsro`: never one macOS uses (its own `ntfs`, `msdos`, `exfat`, ...), checked by a test.
- Info.plists are generated from `DiskFormat` (`swift package plists`), with a drift check among the gates; the first run caught a
  hand-written plist that disagreed with the registry.
- Probes answer "usable but limited": read-only is a limitation. Ownership is ignored (`FSVolumeAlwaysIgnoreOwnership`): Linux and Windows
  owners mean nothing on this Mac.
- The reader error type is `DiskError`: FSKit already has an `FSError`, and every consumer imports both.

## Open questions (not verified)

Whether `usableButLimited` still lets Disk Arbitration mount automatically; whether the media-type keys are honoured without an
`FSProbeExecutable`. Both need a signed, enabled module (roadmap 0006).
