---
status: accepted
date: 2026-10-30
---

# 0005 — Mount technologies, and why FSKit is the native one

## Context

macOS offers several ways to put a foreign volume in Finder: an FSKit module (user space, macOS 15.4+, block devices; the macOS 27
`FSVolume.Handler` API), a kernel extension using the VFS KPIs, a loopback server mounted by a native client (NFS, SMB, WebDAV), or File
Provider. NTFS-C (ninerf/NTFS-C) shows the kernel route as users meet it: macFUSE plus ntfs-3g, which needs Reduced Security and an
approved kernel extension on Apple Silicon.

## Decision

1. **FSKit is the native path** and is built first: one module per format, read-only, on the macOS 27 Handler API.
2. **Loopback proxies are the no-entitlement path**, mounted by macOS's own clients: NFSv3 first (ranged reads by design), WebDAV as one
   option among others, never the only one (roadmap 0007, 0008).
3. **The in-app browser** needs nothing installed and is always available.
4. **A kernel extension is not built.** It needs Reduced Security on Apple Silicon, uses KPIs Apple steers away from, cannot run the Swift
   readers, and could not be loaded on this machine to be tested. Roadmap 0009 keeps the research question open.
5. **File Provider is not used** for block volumes: it materialises files, and Everest reports it ignores ranged requests.

## Consequences

`MountKit` holds what every technology shares (identifiers, listings), so a proxy reuses it unchanged.
