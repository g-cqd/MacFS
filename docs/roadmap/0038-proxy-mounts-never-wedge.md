---
status: in-progress
blocked-by: []
date: 2026-10-30
---

# 0038 — Proxy mounts never wedge

Everest's worst failure is a volume whose server is gone: every reader hangs (research 2026-10-30-everest-code-review #4, #8, #10,
#13). `macfs-nfsd` prints a hard mount, so the same holds here. Test first, then measured with `mount_nfs`:

- Mount options built by one tested function: `soft` and a bounded `deadtimeout` (the kernel unmounts a dead server, even after
  `kill -9`), `intr`, `rdonly`, `locallocks`, the port for both programs.
- A secret export: MOUNT answers only `/<token>`; anything else is refused, so another local process cannot mount by guessing.
- `LoopbackServer`: a connection cap, and receive and send timeouts, so a client that stops reading costs a thread for a bounded time.
- Calls answered concurrently within a connection (replies matched by xid), so a large READ does not hold back LOOKUPs.
- The proxy's parsers get an adversarial suite (hostile records, XDR, handles, names).

## Progress

Done, red first (ADR-0014): `NFSMountCommand` (soft, `intr`, `deadtimeout=10`, `rsize=131072`), `NFSExport` (secret path, one MNT,
nothing listed, a secret in every handle), `LoopbackServer.Limits` (16 connections, 300 s idle, 30 s without write progress, no
SIGPIPE, eight concurrent calls per connection, replies whole), and `BoundedCache` making a concurrent miss once, which concurrency
needed (Btrfs verified a MiB eight times). Measured with `mount_nfs`: after `kill -9`, readers fail in 8 s and the mount is gone in
19 s; 128 KiB reads 1.4 to 1.6 times faster; concurrency doubles compressed reads (docs/conformance/performance.md). Mutants:
239, 56 not compiling, 147 killed, 36 equivalent (diary 2026-10-30-22). Open: the adversarial suite for the proxy's parsers.
