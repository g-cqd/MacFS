---
status: open
blocked-by: ["0035"]
date: 2026-10-30
---

# 0036 — A File Provider backend

A Finder sidebar domain over an image, needing no FSKit module, surviving quit. Whole-file fetches only (Everest measured ranged
reads ignored: `fetchPartialContents` never called), so it suits images of small files; the mount sheet says when to prefer another
backend. From Everest (research 2026-10-30-everest-code-review #19): a removal policy (keep or discard downloads, the kept folder
reported), the local storage a domain holds, eviction without unmounting, and fetches streamed to disk, never buffered whole.
