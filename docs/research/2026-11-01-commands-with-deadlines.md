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

## Addendum: live, a frozen NFS server (same day)

`macfs-nfsd` serving the ext4 image, mounted with the proxy's own `mount_nfs` options (soft, `deadtimeout=10`), then stopped
with SIGSTOP. The backend's sequence through the runner (`umount` with a 10 s deadline, then `umount -f`), from a harness linking
`SystemCommands`:

| Run | Result |
|---|---|
| plain `umount` from a shell | returned after 21 s, unmounted |
| runner, first version | stopped at 10 s, but the call returned at **16.6 s**: SIGKILL cannot end a process in the kernel, and the runner waited for its reap |
| runner, with the caller bounded to deadline + grace + 1 s | returned at **13.0 s**, status 124, "nor end after SIGKILL"; the kernel finished the unmount itself |
| runner, the kernel faster | `umount` succeeded at 6 s |
| a reader holding the frozen mount | `umount` "Resource busy" at once, `umount -f` in 1.6 s |

No stray `umount` and no mount were left after any run.

## Addendum: the cooperative pool

With eleven of its tests running at once, each calling the synchronous runner from a Swift Testing task, the suite reported
commands that had finished as timed out: each call blocked a pool thread, and the commands' own tasks found none free. That is
Everest's deadlock, reproduced. The runner now refuses a call made from a task (`withUnsafeCurrentTask`), and its tests call it
from threads of their own, as the agent does from its XPC queue.
