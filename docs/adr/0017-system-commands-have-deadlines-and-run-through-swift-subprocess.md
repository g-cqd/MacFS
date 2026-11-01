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
2. Each command gets a deadline (60 s by default), its own process group and a teardown: SIGTERM to the group, then SIGKILL
   after a grace period (2 s). A stopped command reports status 124 and says it was stopped; one that could not start reports
   127; one killed by a signal reports 128 plus the signal.
3. Output is streamed: each stream keeps its first 64 KiB and the rest is read and dropped, so the status always survives.
   The output is standard output, then standard error.
4. `CommandRunning` stays synchronous. The runner blocks its caller on a semaphore while a detached task runs the command, so
   it must never be called from the cooperative pool. The agent calls it from its XPC queues and `macfs-nfsd` from its own
   thread.
5. MountKit keeps only the protocol: the FSKit modules link it and must not carry the library.

## Consequences

A hung `umount` or `mount_nfs` costs at most the deadline plus the grace period, and leaves nothing behind. The agent grew by
841 KB; the modules did not change. A command stuck in the kernel cannot be killed, and the runner then waits for the teardown
(not measured). Tooling's runner stays on `Process` until it gets a policy for the end of the output (roadmap 0048).
