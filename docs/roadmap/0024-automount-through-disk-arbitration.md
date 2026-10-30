---
status: open
blocked-by: []
date: 2026-10-30
---

# 0024 — Automatic mounting through Disk Arbitration

`hdiutil attach -readonly` of an ext4 image says "no mountable file systems" with the modules enabled, and no log line shows a probe of
ours. Candidates, none tested: modules without `FSProbeExecutable` are not probed for these media types; a partitionless image is not
matched by the `Partitionless` hint; `usableButLimited` is not mounted automatically. Probe each, with a partitioned image too.
