---
status: done
blocked-by: []
date: 2026-10-30
---

# 0010 — Pinned fcheck and modeler

Release archives with SHA-256 pins, as deadwood, dolly and arcleak have. Until then they come from `MACFS_FCHECK` and `MACFS_MODELER`.

## Done

fcheck and modeler have releases now, and the family pins all five analyzers in one lock (aemi `Scripts/analyzers.lock`: version
and SHA-256 per platform). MacFS copies it to `Scripts/analyzers.lock`; `AnalyzerLock` reads it, `ToolLocator` finds the tools in
the shared cache, `AnalyzerInstaller` downloads a missing release and refuses it unless the hash and `--version` match (tests red
first, with a fake runner and real files). `gates` installs before running: no environment needed. Moved deadwood 0.11.1 → 0.13.0,
dolly 0.11.0 → 0.13.0, arcleak 0.12.0 → 0.15.0, fcheck and modeler from local builds to 0.4.0: no new finding.
