---
status: open
blocked-by: []
date: 2026-10-30
---

# 0043 — A request trace, and diagnostics that include mounts

Everest turned "it stalls" into a specific request with a per-request log and a probe that serves and traces (research
2026-10-30-everest-code-review #11, #16). `macfs-nfsd --trace`: one line per call (procedure, handle, offset, count, status, time).
With it, measure what Finder asks of a proxy mount (sidecar probes, attribute storms) before answering any of it from a cache. The
app's "Copy Diagnostics" adds the agent's recent mount events (0039).
