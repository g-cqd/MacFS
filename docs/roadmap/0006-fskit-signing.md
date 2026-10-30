---
status: done
blocked-by: []
date: 2026-10-30
---

# 0006 — Signing with the FSKit Module capability

## Done

`xcodebuild -allowProvisioningUpdates` with automatic signing (team NP94WB3P75, identity "the personal Apple Development identity
(<identity>)") registered the App IDs and issued one "Mac Team Provisioning Profile" per module, each granting
`com.apple.developer.fskit.fsmodule` (expires 2027-10-30). No portal step was needed: the account already allows the capability.

| Bundle | App ID | Entitlements |
|---|---|---|
| `MacFS.app` | `NP94WB3P75.dev.gcqd.MacFS` | app sandbox, user-selected files (no profile needed) |
| `BtrfsFS.appex` | `NP94WB3P75.dev.gcqd.MacFS.BtrfsFS` | fsmodule, app sandbox |
| `NTFSFS.appex` | `NP94WB3P75.dev.gcqd.MacFS.NTFSFS` | fsmodule, app sandbox |
| `ExtFSModule.appex` | `NP94WB3P75.dev.gcqd.MacFS.ExtFSModule` | fsmodule, app sandbox |

`codesign --verify --deep --strict` passes; the three modules are registered with `pluginkit` from `/Applications/MacFS.app`.
Development profiles only: a Developer ID build for other Macs is not done.
