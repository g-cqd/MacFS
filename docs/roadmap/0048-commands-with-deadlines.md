---
status: done
blocked-by: []
date: 2026-11-01
---

# 0048 — Commands with deadlines

No command MacFS runs may wait forever or keep unbounded output (ADR-0017, research 2026-11-01-commands-with-deadlines).

1. **Done:** the agent's `SystemCommandRunner` on swift-subprocess, in the `SystemCommands` target: a deadline, its own process
   group, SIGTERM then SIGKILL, the first 64 KiB of each stream. 7 tests, seen failing on the old runner; 10 hand mutants killed.
   Live: install, FSKit 18/18, agent 18/18.
2. **Done:** a deadline per call in the seam; the backend gives `mount_nfs` 30 s and each `umount` 10 s, and forces off a mount
   that came up after its `mount_nfs` failed, before the proxy stops (4 tests, 6 mutants killed, 1 equivalent).
3. **Done, live:** a mount of a frozen `macfs-nfsd` (SIGSTOP). A plain `umount` took 21 s. Through the runner: stopped at 10 s;
   once SIGKILL could not end it (stuck in the kernel) the call returned at 16.6 s, and after the caller's bound was added at
   13.0 s (deadline + grace + 1 s); the kernel finished the unmount itself; nothing left running.
4. **Done:** Tooling's `SystemProcessRunner` on `SystemCommands` (`.last(256 KiB)` captured, `.passedThrough` otherwise), with
   `macfs-tool`'s deadlines: 2 h a gates or images step, 30 min a build step, 10 min a download, 2 min a mount-check step.

The runner: 15 tests, mutants killed but for two equivalents (the export's random path; a transient peak in the tail). Live: two
installs with the mount check (FSKit 18/18, agent 18/18 each), the gates.
