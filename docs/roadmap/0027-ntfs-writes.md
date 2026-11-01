---
status: open
blocked-by: []
date: 2026-10-30
---

# 0027 — Writes for NTFS

`$MFT` records, `$Bitmap`, index B+ trees, fixups on write, `$LogFile` handling (or refusing volumes that need it), and the
hibernation and dirty-volume refusals NTFS-C documents. Checked by `ntfsfix -n` and a tree compare.
