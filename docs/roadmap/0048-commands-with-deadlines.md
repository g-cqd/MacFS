---
status: open
blocked-by: []
date: 2026-11-01
---

# 0048 — Commands with deadlines

No command MacFS runs may wait forever or keep unbounded output (ADR-0017, research 2026-11-01-commands-with-deadlines).

1. **Done:** the agent's `SystemCommandRunner` on swift-subprocess, in the `SystemCommands` target: a deadline, its own process
   group, SIGTERM then SIGKILL, the first 64 KiB of each stream. 7 tests, seen failing on the old runner; 10 hand mutants killed.
   Live: install, FSKit 18/18, agent 18/18.
2. A deadline per command in the backend: `umount` short, then `umount -f`; `mount_nfs` longer.
3. A live check that a hung `umount` (a mount of a stopped proxy) returns within the deadline.
4. Tooling's `SystemProcessRunner` on `SystemCommands`, keeping the last bytes of the output (the installer shows xcodebuild's
   last line), with deadlines sized for builds.
