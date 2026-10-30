---
status: accepted
date: 2026-10-30
---

# 0010 — The NFS proxy is NFSv3 over loopback TCP, without a portmapper

## Context

The no-entitlement path (ADR-0005) needs a protocol macOS's own client speaks, that reads by range, and that a small server can
implement exactly. Everest reports WebDAV clients fetching whole files; NFS reads are ranged by design.

## Decision

- **NFSv3 and MOUNT v3 (RFC 1813), read-only**, in `NFSProxy`: GETATTR, LOOKUP, ACCESS, READLINK, READ, READDIR, READDIRPLUS, FSSTAT,
  FSINFO, PATHCONF. Every procedure that would write answers NFS3ERR_ROFS; ACCESS never grants modify, extend or delete.
- **TCP on 127.0.0.1 only**, one port for both programs, given to `mount_nfs` as `port=` and `mountport=`: no portmapper, nothing
  reachable from the network.
- **The server is a function** (`NFSDispatcher.handle`: one call in, one reply out) over `MountedTree`, so identifiers, `.` and `..`
  and cookies are the ones FSKit uses and Lean proves. Sockets are a thin shell (`LoopbackServer`).
- **Handles** are "MFS3", four bytes of the volume identifier, and the mount identifier; any other handle is NFS3ERR_BADHANDLE.
- **Owners** are the serving user's, as `noowners` shows them under FSKit. Free space reads as available, as FSKit reports it.
- **Every length from a client is bounded** (`XDRReader`, `RecordReader` at 2 MiB): clients are as untrusted as disks.

## Consequences

`macfs-nfsd <image>` serves and prints the mount command; the user mounts with no privilege. WebDAV remains one option (roadmap 0008).
Not done: AUTH checks (any local user may connect; the data is what that user could read from the image anyway), NFSv4, locking.
