---
status: done
blocked-by: []
date: 2026-10-30
---

# 0007 — Loopback NFSv3 proxy

A read-only NFSv3 server on loopback over `MountedTree`, mounted with `mount_nfs` (native client, no entitlement). Ranged reads are the
protocol's unit, which is what WebDAV lacks (Everest reports Finder fetching whole files). Test-first against a recorded client trace.

## Done

`NFSProxy` and `macfs-nfsd` (ADR-0010). Red first: XDR against hand-worked bytes, every procedure against the in-memory file system,
the socket server over loopback (16 tests). Then `mount_nfs` as the user, no sudo: all eleven images matched their manifests through
the native client, writes answered "Read-only file system".
