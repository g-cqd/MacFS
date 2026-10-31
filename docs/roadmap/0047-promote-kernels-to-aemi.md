---
status: open
blocked-by: []
date: 2026-10-30
---

# 0047 — Promote MacFS's kernels and technologies to aemi

The owner asks that MacFS's improvements live in aemi where they are not about file systems (research 2026-10-30-promoting-to-aemi).
CRC-32C, the bit count and UTF-16 narrowing went first (aemi ADR 0020, MacFS ADR-0012). Next, in order, each through an aemi ADR with
tests seen failing in aemi first, aemi's `-Os` bench and sanitized scripts, then MacFS pinning the revision and deleting its copy:

1. `BoundedCache` with coalesced misses → `AemiRuntime`.
2. Inflate, then the zstd and LZO1X decoders as C → a codecs module (libz and the zstd CLI as oracles).
3. An aemi ADR admitting arm64 assembly on ADR-0011's terms, `KernelABI` → AemiTestKit; then the zstd sequence loop and LZO1X.
4. Checked big- and little-endian loads (`DiskBytes`) → `CheckedBytes`.
5. Mutation testing as an aemi command plugin, replacing the harnesses in /tmp.

Staying in MacFS: the NTFS fixups, device ioctls, readers, `MountedTree`, the NFS proxy. LZNT1 moves only with a second user.
