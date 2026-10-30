---
status: done
blocked-by: []
date: 2026-10-30
---

# 0024 — Automatic mounting through Disk Arbitration

`hdiutil attach -readonly` of an ext4 image says "no mountable file systems" with the modules enabled, and no log line shows a probe of
ours. Candidates, none tested: modules without `FSProbeExecutable` are not probed for these media types; a partitionless image is not
matched by the `Partitionless` hint; `usableButLimited` is not mounted automatically. Probe each, with a partitioned image too.

## Done

The third candidate: Disk Arbitration treats `usableButLimited` as a failed probe. Modules answer `usable` (ADR-0009). Partitionless
Btrfs and ext images and a GPT "Linux filesystem" partition (`ext4-gpt` image) mount on attach and match their manifests.
