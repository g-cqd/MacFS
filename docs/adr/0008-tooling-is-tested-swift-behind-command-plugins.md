---
status: accepted
date: 2026-10-30
---

# 0008 — Tooling is tested Swift behind command plugins

## Decision

Scripts became `Packages/Tooling`: `ToolingCore` holds the logic (plans, tool location, plist generation, repository rules, test-output
summary), `macfs-tool` is the front end, and three command plugins (`images`, `gates`, `plists`) call it. Every plan prints itself with
`--dry-run` before anything runs; `ProcessRunning` is the one seam to the system and tests use a recording mock that runs nothing. Tools
are located by `MACFS_<NAME>`, then pinned caches, then `PATH`. The only shell left is the payload that runs inside the Linux container.

## Consequences

`macfs-tool summary` reduces `swift test` output to failures and totals (it replaced two shell helpers).
fcheck and modeler have no release archives yet, so they come from an override (roadmap 0010).
