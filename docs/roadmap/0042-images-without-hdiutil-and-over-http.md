---
status: open
blocked-by: []
date: 2026-10-30
---

# 0042 — Images without `hdiutil`, and images over HTTP

Everest's FSKit volume reads a URL (`FSGenericURLResource`, macOS 26), one read to one HTTP range (research
2026-10-30-everest-code-review #18). Two possibilities for MacFS, each probed before it is built:

- `FSPathURLResource` (macOS 26): the modules mount an image file directly, with no disk image attached; what Info.plist keys and
  entitlements it needs, and whether Disk Arbitration or `mount -F` reaches it.
- A ranged-HTTP `BlockSource`: an image on a NAS or a web server read by range, with 0040's read-ahead and Everest's scheduling (a
  bounded number of requests, interactive reads first), behind the same readers.
