---
status: open
blocked-by: []
date: 2026-10-30
---

# 0046 — Writes through every mount path

A format that can write is not a writable disk until the path that mounts it carries the writes; each is read-only today by decision
(ADR-0006, ADR-0010, 0008). Per path: FSKit (the volume's write, create, remove, rename and set-attribute operations, and the
kernel-offloaded write mapping), the NFS proxy (WRITE, CREATE, MKDIR, REMOVE, RENAME, SETATTR, and COMMIT with stable-storage
semantics), WebDAV (PUT, DELETE, MKCOL, MOVE, without the Finder sidecar files Everest answers 404), and File Provider (modify, create,
delete). Writable is opt-in per mount, shown in the mount sheet, and every path is checked by the format's own checker (0017's table)
after writes made through it.
