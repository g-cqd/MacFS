---
status: open
blocked-by: ["0035"]
date: 2026-10-30
---

# 0008 — WebDAV proxy, as one option

A read-only WebDAV source over `MountedTree` for clients that prefer it. Never the default. Everest's WebDAVKit only after its own
tests pass here; it is hosted by the mount agent (0039), not the app, so it survives the app quitting.

Everest's findings apply (research 2026-10-30-everest-features and -code-review #9–#14): keep bytes read past a request head (a
`PROPFIND` body); answer Finder's `._*`, `.DS_Store`, `.metadata_*` and other sidecar probes with 404, and `.ql_disablethumbnails`
too; refuse no-range GETs of large files from `WebDAVFS/` (Quick Look) while serving ranges; schedule explicit ranges before
whole-file GETs; bound the channel to the client and drop a client that makes no progress for 30 s; read-only methods answered 403;
a secret token in the share path, the share name last (NetFS names the volume after it); `mount_webdav -S -v NAME`.
