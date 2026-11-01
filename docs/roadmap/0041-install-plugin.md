---
status: done
blocked-by: []
date: 2026-10-30
---

# 0041 — Install as a tested command plugin

The release steps are typed by hand (AGENTS.md), and one mistake installs a stale build. Everest's `build-install.sh` verifies both
architecture slices and both signatures before replacing the app (research 2026-10-30-everest-code-review #17). `swift package install`
(ToolingCore plan, dry-run tested): generate, build Release, refuse on a non-zero exit, verify the app's and every extension's
signature and entitlements, keep the previous app, copy, re-register, stop the old module processes, run the mount check. A universal
build is an option once x86 is measured natively.

## Done

`swift package --package-path Packages/Tooling --disable-sandbox install [--check] [--dry-run]` (`Installer`, on the recording
runner):
1. xcodegen, then xcodebuild Release run without swiftly's `TOOLCHAINS` and `SDKROOT`; a non-zero exit stops it.
2. The build's checks, each reported before refusing: its signature deep and strict, each part's entitlements (app and agent
   sandboxed with the app group, modules sandboxed FSKit modules), the agent's Info.plist in its binary, and its team.
3. The previous app kept, the build copied in.
4. The build's copy unregistered and removed (it had been registered, and its modules ran instead of the installed ones), the
   installed app registered, the old processes stopped.
5. The installed signature verified, and each module registered once, from `/Applications`.

`--check` runs the mount check after. 20 tests, 20 hand mutants killed. Live: two installs in a row, all four modules enabled
after both, FSKit 18/18, agent 18/18. Not done: universal builds (x86 is still measured only under Rosetta).
