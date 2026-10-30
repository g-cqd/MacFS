---
status: done
blocked-by: []
date: 2026-10-30
---

# 0022 — Unicode normalization in lookups

Linux names are usually NFC; macOS callers may look up NFD. Decide and test a normalization-insensitive lookup.

## Done

Found by the mount check (0025), not by reasoning: through a mount, Cocoa's `FileManager` neither listed nor found
`spaces and ünïcödé/naïve.txt`, because it asks in decomposed form (NFD) and Linux stores precomposed (NFC); Python's byte paths
had hidden it. `lookupCanonical` (FSCore): the exact name wins, and failing that the first canonically equivalent entry
(Swift's `String ==`), as APFS treats names; only non-ASCII misses scan the directory. FSKit's and the NFS proxy's lookups use it;
tests in MountKit (both forms present: the exact one wins) and through the NFS dispatcher.
