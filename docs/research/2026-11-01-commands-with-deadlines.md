# Commands with deadlines: swift-subprocess or our own over `Process` (2026-11-01)

**Question.** The agent runs `mount_nfs` and `umount` with Foundation's `Process`, waiting without a deadline and reading one
merged, unbounded pipe. A hung `umount` of a dead server's mount holds an agent thread forever. Should the deadline come from
swiftlang's swift-subprocess (1.0.2), or from our own code over `Process`? The aemi family has no process API.

**Method.** One scratch package, two executables, the same four commands, a 1 s deadline and a 1 s grace period
(`probes/subprocess-deadline.swift.txt`, `probes/process-deadline.swift.txt`). Both are called synchronously from a plain thread,
as the agent calls them from its XPC queue. macOS 27, M2 Pro, Swift 6.4, release builds.

## Results

| Case | swift-subprocess 1.0.2 (own process group, group teardown) | `Process` + semaphore, SIGTERM then SIGKILL |
|---|---|---|
| `echo out; echo err >&2` | 0.00 s, both streams | 0.01 s, both streams |
| `sleep 100` | stopped at 1.02 s | stopped at 1.00 s |
| `sh` ignoring SIGTERM, a grandchild `sleep` | killed at 2.02 s, **nothing left running** | SIGKILL at 2 s, then **4.01 s waiting on the pipe the orphaned grandchild still holds; the grandchild left running** |
| 50 MB of output, a 64 KiB limit | `.string(limit:)` **throws** past the limit and the status is lost; streaming (`.sequence`, keep 64 KiB, drop the rest): exit 0 in 0.03 s | all 50 MB read into memory |
| A pipe without `FD_CLOEXEC` in the parent | not inherited (the child sees 0, 1, 2) | not inherited |
| Binary / clean release build | 914 KB / 15.3 s | 68 KB / 6.5 s |

The orphan count was taken after a `kill -9` cleanup: a plain `pkill` sends SIGTERM, which the test's `sleep` ignores, and an
earlier count was stale. `Process` cannot put its child in a process group of its own, so killing what the command started
would mean writing our own `posix_spawn` with `POSIX_SPAWN_SETPGROUP`, which is what swift-subprocess already is.

swift-subprocess's teardown runs when the task running the command is cancelled (`onCleanup`), so a deadline is a task group
racing the command against a sleep. On macOS it links only the SDK's System (swift-system is for other platforms).

## Conclusions

1. swift-subprocess, for the agent: the group teardown is the difference that matters, and it is the library's, maintained by
   swiftlang (ADR-0017).
2. Streaming, not `.string(limit:)`: the status must survive a chatty command.
3. A separate target, so the four FSKit modules, which link MountKit, do not carry it. Measured: the agent grew by 841 KB, the
   modules not at all.
4. Tooling (xcodebuild's minutes of output, of which the installer shows the last line) needs the end of the output rather
   than the start: a later step of roadmap 0048.

Not measured: a command stuck in the kernel (a hard NFS mount), which SIGKILL cannot end; the runner would then wait for the
teardown.
