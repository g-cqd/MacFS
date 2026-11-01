---
status: accepted
date: 2026-10-30
---

# 0004 — One Aemi pin, and Aemi first

## Context

The owner asks that Aemi, AemiJSON, AemiProtobuf and AemiRegex be used wherever they fit. SwiftPM allows one revision of a package per
graph: Tooling depends on AemiRegex at `923d23f`, which pins aemi `04e49d1`, while FSCore pinned `785c6b2`, and resolution failed.

## Decision

Every MacFS package pins aemi at the same revision, moved together with AemiRegex's pin of it: aemi `8475434` and AemiRegex
`1500307` since 2026-11-01 (first `04e49d1`, then `2fbe4e4`). Used today: AemiKernel
(unaligned little-endian loads, checked arithmetic, XXH64 for Btrfs xxhash checksums), AemiIO (`PosixFile`), AemiRegex (repository
rules in Tooling), Aemi's `format` and `lint` plugins and the canonical `.swift-format` and `.swiftlint.yml`. Reserved: AemiProtobuf
for the proxy helper's IPC and AemiJSON for configuration and reports, when those exist; nothing is added before it is used.

## Consequences

The analyzers are pinned the same way, by the family's lock: `Scripts/analyzers.lock` is aemi's, copied, and moves with the aemi pin
(roadmap 0010). AemiJSON (head pins aemi `8475434`) and AemiProtobuf (head pins aemi `a20fb18` and AemiJSON `0869500`) join a MacFS
graph only when they pin the same aemi as MacFS. On 2026-11-01 AemiJSON did; AemiProtobuf was bumped to aemi `8475434` and
AemiJSON `1a79d01` (`7b7dbc5`, its own gates green) and is chosen for the registry and the agent's messages (ADR-0015).

`DiskBytes` wraps Aemi's loads with the bounds check they leave to the caller, because Aemi checks only in debug and disk bytes are
hostile. Info.plists are property lists, so `PropertyListSerialization` writes them, not a JSON library.
