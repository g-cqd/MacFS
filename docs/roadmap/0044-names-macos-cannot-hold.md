---
status: open
blocked-by: []
date: 2026-10-30
---

# 0044 — Names macOS cannot hold

Linux names are bytes: not UTF-8, `:` (Finder shows `/`), control bytes, names equal but for case. Everest maps hostile titles to
legal, stable, unique names (`FileNameMapper`; research 2026-10-30-everest-code-review #20); MacFS must first see what FSKit, the NFS
client and Finder do with each, through a mount, as 0022 found the NFD case. Then decide per case: shown as is, escaped reversibly,
or refused with a reason.
