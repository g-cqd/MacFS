# Everest, read at the code: what MacFS takes, and how it does better (2026-10-30)

**Sources.** Everest at `~/Developer/ongoing/swift/Everest` (no git history; read as found): `EverestCore` (`MountBackend`,
`MountBackendKind`, `MountService`, `WebDAVBackend`, `WebDAVMounter`, `MediaBlockCache`, `MountRemovalPolicy`, `FileLogger`),
`WebDAVKit` (`WebDAVRequestHandler`, `WebDAVSource`, `ConnectionSocket`, `ReadBackoff`), `UPnPKit` (`RequestLimiter`,
`FileNameMapper`, `AddressPolicy`, the adversarial suite), the app, `Scripts/` and the README's findings table. `man mount_nfs`
(macOS 27.2). apple-docs: FSKit resources, `SMAppService`. Follows the first reading, research 2026-10-30-everest-features, which took
the app-level findings (in /Applications, reveal out of process, settings panes). ADR-0001 holds: findings, not code.

## What Everest is, as a design

A sandboxed-extension app that mounts one kind of source three ways behind one protocol (`MountBackend`): a loopback WebDAV server
in the app mounted with `mount_webdav -S` (streams; dies with the app), a File Provider domain (survives quit; whole files only, ranged
fetches measured ignored), and an FSKit module over `FSGenericURLResource` (macOS 26; written, not shipped for want of the
entitlement). Its findings are measured, which is what makes them worth taking.

## Its weaknesses, which MacFS must not copy

| Where | What | Consequence |
|---|---|---|
| `WebDAVBackend` lives in the app | "Everest *is* the server" | Every streaming mount dies when the app quits or crashes; the README lists it as a limitation |
| `MountService.backend(for: .fsKit)` | A stored FSKit choice silently gets WebDAV | The user asked for one technology and gets another, unannounced |
| `MountService.changeBackend` | Unmounts the old, then mounts the new | A failed mount leaves nothing mounted, and nothing records what was |
| `WebDAVBackend.mounted()` | Returns `[]`: shares live in memory | After a crash only a directory scan finds the leftovers; no record says which mount was whose |
| `WebDAVMounter.clearStaleMounts` | Any mount point under its directory is "ours" | Correct only while nothing else mounts there; it never checks what is mounted |
| Death detection | The serving task ending triggers an unmount; `-S` covers a hung server | A `kill -9` of the app leaves the unmount to the kext's own timeout, not to anything Everest checks |
| `MediaBlockCache` | LRU as an array (`firstIndex`, `removeFirst`) | O(n) per touch; fine at 128 blocks, a trap if copied at reader scale |
| Tests | 13 in EverestCore; mount behaviour proved by live runs | The lifecycle (mount, death, sweep, backend change) has no model and no fault-injection test |

## Feature by feature

| # | Everest | MacFS, improved | Roadmap |
|---|---|---|---|
| 1 | `MountBackend`: kind, `canMount`, idempotent mount, tolerant unmount, `mounted()` | Same seam in `MountKit`, plus a **persisted registry** (backend, source, mount point, export token, owner) as the source of truth, so routing survives a crash | 0035 |
| 2 | `MountBackendKind`: `streams`, `survivesAppQuit`, `minimumMacOS`, `isAvailable` (module embedded) | A pure capability evaluation from system facts, like `StatusEvaluation`: each backend's tradeoffs, and **why** one is unavailable, shown; **never a silent substitute** | 0035 |
| 3 | `changeBackend`: break, then make | **Make before break**: a read-only source can be mounted twice, so the new mount comes up first and the old goes only once it has | 0035 |
| 4 | Server task ends → unmount; `mount_webdav -S` unmounts a dead server | NFS's own: `soft` with a bounded `deadtimeout` (the kernel unmounts a dead server even after `kill -9`), plus the owner unmounting when a server stops | 0038 |
| 5 | Stale mounts cleared at launch by device number under its directory | Swept from the registry and checked against `statfs` (`f_mntfromname` = this proxy's export), so only MacFS's own mounts are touched | 0035, 0038 |
| 6 | Teardown in `NSApplicationDelegate` (SwiftUI `.task` cancels on view churn) | Proxy mounts are owned by a **launchd agent**, not the app: they survive quitting the app, which removes Everest's main limitation; the app's quit tears nothing down | 0039 |
| 7 | `Process.waitUntilExit` on its own thread, off the cooperative pool | A `ProcessRunning` seam in MountKit (Tooling has one): mount commands are tested with a fake, run on a thread | 0035 |
| 8 | Secret token in the share URL, share name last (NetFS names the volume after the last segment) | The NFS export is `/<token>`: the MOUNT program answers only that path, so another local process cannot mount the proxy by guessing `/` | 0038 |
| 9 | Head reader kept bytes past the terminator only after a hang (`PROPFIND` bodies; curl sends none) | Already so in `RecordReader`; the lesson kept: protocol tests replay the **real client's** traffic, not a convenient one | 0038 |
| 10 | Idle timeout (60 s), head cap (16 KiB), write abandoned after 30 s without progress | Per-connection receive and send timeouts and a connection cap in `LoopbackServer` (it has a record cap, 2 MiB, and nothing else) | 0038 |
| 11 | Sidecar probes (`._*`, `.DS_Store`, `.metadata_*`, `.Spotlight-V100`, …) answered 404 at once; `.ql_disablethumbnails` makes things worse | Measured first through the proxy's trace: on a real image these names are absent and cost one lookup each; answer from a negative cache only if the trace shows the cost | 0043 |
| 12 | Quick Look's no-range whole-file GETs over 32 MiB refused (403), ranged reads served | Kept for the WebDAV option, which has the problem; NFS reads are ranged by protocol | 0008 |
| 13 | `RequestLimiter`: control, interactive and bulk classes; bulk one at a time; cancelled waiters dropped | The NFS proxy answers each connection's calls **in order**, so one 1 MiB READ delays every LOOKUP behind it: answer calls concurrently, by xid, with a bounded pool and lookups first | 0038 |
| 14 | Bounded channel between upstream and socket (backpressure) | Blocking sockets with a send timeout give the same bound per thread; kept explicit in the WebDAV option | 0008, 0038 |
| 15 | `MediaBlockCache`: sequential detection, read-ahead only once reads march forward, small scattered reads fetched exact, bounded memory, in-flight fetches shared, speculative work only when idle | Applied where MacFS amplifies: compressed extents (a 4 KiB read of a 128 KiB zstd extent), and a future network block source; with Everest's own test, **bytes pulled per byte asked**, as a budget per reader | 0040 |
| 16 | `FileLogger`, `logs.sh`, `everest-dav-probe` (serve and trace every request) | `macfs-nfsd --trace` (procedure, handle, offset, count, status, time) and the agent's events in "Copy Diagnostics" | 0043 |
| 17 | `build-install.sh`: Release by default, both architecture slices and both signatures verified **before** replacing the app; a stable identity so TCC grants survive | MacFS installs by hand (AGENTS.md's release steps): a tested `install` command plugin that builds, refuses on a failed build, verifies every bundle's signature and entitlements, keeps the previous app, re-registers and runs the mount check | 0041 |
| 18 | `FSGenericURLResource` (macOS 26): an FSKit volume over a URL, one read → one HTTP range | Two possibilities: `FSPathURLResource` mounts an **image file** with no `hdiutil` attach; and a ranged-HTTP `BlockSource` reads an image on a NAS or web server, with #15's read-ahead | 0042 |
| 19 | File Provider: survives quit, offline copies, keep or discard downloads, evict, storage size | As planned, for images of small files, with the removal policy and storage report | 0036 |
| 20 | `FileNameMapper`: `/`, NUL, control, `.`/`..`, 255-byte cap, case-insensitive collisions | Linux names are bytes: not UTF-8, `:`, control bytes, case twins. Probe what Finder, NFS and FSKit do with each (0022 found the NFD case this way) before mapping anything | 0044 |
| 21 | Adversarial suite (XXE, entity expansion, hostile names, SSRF, SOAP injection) | The proxy's parsers get the same: hostile records, XDR, handles and names, beside the readers' fuzzing | 0023, 0038 |
| 22 | Universal build (arm64 and x86_64) | MacFS's assembly has portable C twins; a universal build is a release option once x86 runs natively, not only under Rosetta | 0041 |
| — | UPnP discovery, SSDP per interface, media-player Services, Local Network permission | No network sources; local volumes stream natively | Not applicable |

## Measured here

- `man mount_nfs`: "mounts which are both soft and read-only will also have the deadtimeout mount option set to 60 seconds", and
  "mark the mount as dead so that it will be forcibly unmounted". `macfs-nfsd` prints `vers=3,tcp,port,mountport,rdonly,locallocks`:
  hard, so a dead proxy hangs every reader of the mount, which is Everest's worst failure.
- `/Volumes` is `root:wheel 755`: a user's mount points live elsewhere, as Everest found.
- The app is sandboxed (`com.apple.security.app-sandbox`): it cannot run `mount_nfs`, so it cannot own proxy mounts. Everest is not
  sandboxed for exactly that reason. An agent (#6) keeps the app sandboxed.
- AemiJSON pins its own AemiRegex (`4ddbcd4`) and pulls swift-syntax; the registry's format waits on a resolution check (ADR-0004).
