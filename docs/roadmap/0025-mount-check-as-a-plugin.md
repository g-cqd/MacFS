---
status: open
blocked-by: []
date: 2026-10-30
---

# 0025 — The mount check as a tested plugin

Today the end-to-end check (attach, `mount -F`, walk, compare with the manifest, write refused, unmount, detach) is a probe script.
Make it `swift package mounts [--dry-run]` in Tooling: the plan tested with the recording runner, the comparison shared with
`ImageOracle`, run in the gates when the modules are enabled.
