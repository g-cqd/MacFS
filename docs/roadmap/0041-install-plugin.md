---
status: open
blocked-by: []
date: 2026-10-30
---

# 0041 — Install as a tested command plugin

The release steps are typed by hand (AGENTS.md), and one mistake installs a stale build. Everest's `build-install.sh` verifies both
architecture slices and both signatures before replacing the app (research 2026-10-30-everest-code-review #17). `swift package install`
(ToolingCore plan, dry-run tested): generate, build Release, refuse on a non-zero exit, verify the app's and every extension's
signature and entitlements, keep the previous app, copy, re-register, stop the old module processes, run the mount check. A universal
build is an option once x86 is measured natively.
