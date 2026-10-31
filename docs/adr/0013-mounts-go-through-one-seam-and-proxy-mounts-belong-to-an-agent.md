---
status: accepted
date: 2026-10-30
---

# 0013 — Mounts go through one seam, and proxy mounts belong to an agent

## Context

MacFS mounts a volume four ways (ADR-0005): FSKit, the NFS proxy, WebDAV (0008) and File Provider (0036). Today each is a separate
path: Disk Arbitration for FSKit, `macfs-nfsd` and a hand-typed `mount_nfs` for the proxy. Everest put its three behind one protocol,
and its code shows what that protocol needs and what it lacked (research 2026-10-30-everest-code-review): its streaming mounts die with
the app, a stored choice can be silently replaced, a backend change can leave nothing mounted, and only a directory scan knows what
was mounted before a crash. The MacFS app is sandboxed and cannot run `mount_nfs`.

## Decision

1. **One seam.** `MountBackend` in `MountKit`: `canMount` with a reason when not, idempotent `mount`, `unmount` that tolerates a mount
   already gone, `mounted`. A `MountService` routes every request to the backend that mounted it. Capabilities (streams, survives the
   app quitting, needs a module, minimum macOS) are evaluated from system facts by a pure function, like `StatusEvaluation`.
2. **No silent substitution.** A backend that cannot mount says why; nothing else is mounted in its place.
3. **A persisted registry is the truth.** Each mount is recorded (backend, source, mount point, export token, owner process) before
   it is attempted and cleared after it is gone. Launch sweeps the registry against `statfs`, touching only mounts it can prove
   are MacFS's.
4. **Make before break.** Changing a mount's backend mounts the new one first; the old one goes only once the new one is up.
5. **Proxy mounts never wedge.** Every proxy mount is soft with a bounded dead timeout, so the kernel unmounts a dead server even
   after `kill -9`; the owner also unmounts when its server stops. Exports are a per-mount secret path.
6. **Proxy mounts belong to a launchd agent**, registered with `SMAppService.agent`, unsandboxed, reached over XPC (AemiProtobuf
   messages, ADR-0004). It hosts the servers, runs the mount commands and keeps the registry. Quitting the app leaves its mounts up;
   the app stays sandboxed.
7. **The lifecycle is modelled.** A TLA+ specification of mount, server death, unmount, sweep and backend change, checked by TLC in
   the gates, with the invariants: never a mount without a live server or a pending dead timeout, never two registry entries for one
   mount point, an unmount always reaches the backend that mounted.

## Consequences

The agent is a second executable with its own signing and an approval in Login Items, which the status pane reports like the
modules. `macfs-nfsd` stays as the no-agent path for scripts. The order of work is: the seam, registry and NFS options in
`MountKit` with fakes (0035, 0038); the TLA+ model (0035); the agent (0039); then WebDAV and File Provider behind the same seam.
