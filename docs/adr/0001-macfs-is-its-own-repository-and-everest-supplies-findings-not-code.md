---
status: accepted
date: 2026-10-30
---

# 0001 — MacFS is its own repository, and Everest supplies findings, not code

## Context

Everest (`ongoing/swift/Everest`) mounts UPnP servers through three backends behind a `MountBackend` seam and records hard-won
findings (FSKit entitlement, WebDAV stalls, File Provider not streaming). Its owner reports it unreliable and likely buggy.

## Decision

MacFS is a new repository. It takes from Everest the idea of a backend seam, the list of findings as open questions to re-probe, and the
signing lesson. It copies no Everest code. WebDAVKit in particular is not vendored: if a WebDAV proxy is built (roadmap 0008), it is built
test-first here or a tested Everest package is depended on by version after its own tests pass.

## Consequences

Each Everest finding used here is cited as "Everest reports" until a probe in this repository confirms it. The FSKit entitlement finding
was confirmed in part: the template, the shipped msdos module and the SDK all require `com.apple.developer.fskit.fsmodule` (research
2026-10-30-fskit-requirements); whether this account can be granted it was not tested.
