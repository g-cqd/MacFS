---
status: open
blocked-by: []
date: 2026-10-30
---

# 0035 — Mount backends behind one seam

ADR-0013 and research 2026-10-30-everest-code-review (#1–#7). In `MountKit`, tested with fakes before anything mounts:

- `MountBackend` (`canMount` with a reason, idempotent `mount`, tolerant `unmount`, `mounted`) and `MountService`, which routes an
  unmount to the backend that mounted; no silent substitution (Everest maps a missing FSKit module to WebDAV).
- A persisted registry (AemiJSON once it resolves with the aemi pin; ADR-0004), written before a mount is attempted, cleared after
  it is gone; the launch sweep checks each entry against `statfs` and touches only MacFS's own mounts.
- Make before break when a mount changes backend (Everest breaks first).
- Capabilities per backend from system facts, pure and tested, for the app's mount sheet.
- A `ProcessRunning` seam: mount commands tested with a fake, run off the cooperative pool.
- The lifecycle in TLA+, checked by TLC in the gates (ADR-0013's invariants).

The first backend is the NFS proxy over an image file (0038's options); FSKit over a device follows 0021.
