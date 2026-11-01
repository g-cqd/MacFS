---
status: accepted
date: 2026-11-01
---

# 0017 — System commands have deadlines, and run through swift-subprocess

## Context

The agent runs `mount_nfs` and `umount` (ADR-0016) with Foundation's `Process`: no deadline, one merged and unbounded pipe. A
hung command holds an agent thread forever. Research 2026-11-01-commands-with-deadlines measured swift-subprocess 1.0.2 against
a deadline of our own over `Process`. Both stop a command on time and neither leaks descriptors. Only swift-subprocess reaches
what the command started (its own process group, SIGTERM then SIGKILL to the group). Over `Process`, an orphaned grandchild
kept the pipe open and kept running.

## Decision

1. `SystemCommandRunner`, in its own target `SystemCommands`, runs commands through swift-subprocess, pinned exactly (1.0.2).
2. Each call names its deadline (`CommandRunning.run(_:_:timeout:)`): the NFS backend gives `mount_nfs` 30 s and each `umount`
   10 s. Each command gets its own process group and a teardown: SIGTERM to the group, then SIGKILL after a grace period (2 s).
   The caller waits at most deadline + grace + 1 s, even for a command SIGKILL cannot end (one stuck in the kernel, measured
   live on a frozen NFS server); the command is reaped in the background. A stopped command reports status 124 and says how
   it was stopped; one that could not start reports 127; one killed by a signal reports 128 plus the signal.
3. Output is streamed, under one of three policies, and the status always survives: `.first(n)` (the agent: standard output
   then standard error, each to its first n bytes), `.last(n)` (the tooling: both merged as written, to their last n bytes,
   where a build's error is), `.passedThrough` (the gates: our own streams).
4. `CommandRunning` stays synchronous. The runner blocks its caller on a semaphore while a detached task runs the command, so a
   call from a task, whose thread the wait would block, is refused (status 127, saying why): eleven such calls at once, one per
   pool thread, starved the pool, and commands that had finished were reported as timed out. The agent calls it from its XPC
   queues, `macfs-nfsd` and `macfs-tool` from plain threads.
6. A `mount_nfs` that failed (or was stopped) but whose mount came up anyway is forced off before its proxy stops (ADR-0014).
5. MountKit keeps only the protocol: the FSKit modules link it and must not carry the library.

## Consequences

A hung `umount` or `mount_nfs` costs at most the deadline plus the grace period, and leaves nothing behind. The agent grew by
841 KB; the modules did not change. A command stuck in the kernel cannot be killed, and the runner then waits for the teardown
(measured: the caller returned at 13.0 s, the kernel finished the unmount later). Tooling's `SystemProcessRunner` runs on it
too, with a deadline per use (`macfs-tool`'s `Deadline`).
