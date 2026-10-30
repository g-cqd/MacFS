---
status: open
blocked-by: []
date: 2026-10-30
---

# 0007 — Loopback NFSv3 proxy

A read-only NFSv3 server on loopback over `MountedTree`, mounted with `mount_nfs` (native client, no entitlement). Ranged reads are the
protocol's unit, which is what WebDAV lacks (Everest reports Finder fetching whole files). Test-first against a recorded client trace.
