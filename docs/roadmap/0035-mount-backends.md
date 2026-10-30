---
status: open
blocked-by: ["0021"]
date: 2026-10-30
---

# 0035 — Mount backends behind one seam

Everest's `MountBackend`/`MountService` pattern (research 2026-10-30-everest-features): FSKit, the NFS proxy, WebDAV (0008) and
File Provider (0036) behind one protocol, an unmount routed to the backend that mounted, teardown in the app delegate, and stale
mounts cleared at launch.
