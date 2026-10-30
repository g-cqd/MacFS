---
status: open
blocked-by: []
date: 2026-10-30
---

# 0008 — WebDAV proxy, as one option

A read-only WebDAV source over `MountedTree` for clients that prefer it. Never the default. Everest's WebDAVKit only after its own
tests pass here.

Everest's findings apply (research 2026-10-30-everest-features): answer Finder's `._*`, `.DS_Store` and `.metadata_*` probes with
404; refuse no-range GETs of large files (Quick Look); bound the channel to the client; mount with `mount_webdav -S`.
