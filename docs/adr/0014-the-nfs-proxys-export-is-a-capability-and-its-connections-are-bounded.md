---
status: accepted
supersedes: ["0010"]
date: 2026-10-30
---

# 0014 — The NFS proxy's export is a capability, its mounts are soft, its connections bounded

## Context

ADR-0010 made the proxy NFSv3 over loopback TCP without a portmapper and left two things open: any local user could mount it
("the data is what that user could read from the image anyway", which stops being true for a raw device opened with `authopen`),
and nothing bounded a connection but its record size. `macfs-nfsd` printed a hard mount, so a proxy that died hung every reader of
its mount: Everest's worst failure (research 2026-10-30-everest-code-review, roadmap 0038).

## Decision

ADR-0010 stands (NFSv3 and MOUNT v3, read-only, 127.0.0.1, one port, the dispatcher a function over `MountedTree`, bounded lengths),
with these changes:

- **The export is `/macfs-<16 random bytes in hex>`** (`NFSExport`), and MOUNT admits **one** MNT of it: the mount table shows the
  path to every local user once mounted, so a second MNT is MNT3ERR_ACCES. EXPORT lists nothing. One server serves one mount; a
  remount starts a new server.
- **Handles carry the export's 8-byte secret**: "MFS3", four bytes of the volume identifier, the secret, the mount identifier.
  A process that skips MOUNT cannot build one.
- **Mounts are soft** (`NFSMountCommand`): `soft,intr,deadtimeout=10`, so a dead proxy's readers fail and the kernel unmounts it, even
  after `kill -9`; and `rsize=131072`, the proxy's preferred read size.
- **Connections are bounded** (`LoopbackServer.Limits`): 16 at once, dropped after 300 s of silence or 30 s of a write making no
  progress, no SIGPIPE; a connection's calls are answered concurrently, eight at a time, each reply written whole.

## Evidence

`mount_nfs` on macOS 27.2 with `ext4.img`: the mount reads; a second mount is "Permission denied", `/` is "No such file or
directory". After `kill -9` of the proxy, `ls` failed with "Operation timed out" in 8 s and the mount was gone in 19 s. Cold reads of
the bench images (docs/conformance/performance.md): 128 KiB reads 1.4 to 1.6 times faster than the client's 32 KiB default;
concurrent calls doubled compressed Btrfs once concurrent misses of one cache key were made once (`BoundedCache`).
