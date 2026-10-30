---
status: accepted
date: 2026-10-30
---

# 0004 — One Aemi pin, and Aemi first

## Context

The owner asks that Aemi, AemiJSON, AemiProtobuf and AemiRegex be used wherever they fit. SwiftPM allows one revision of a package per
graph: Tooling depends on AemiRegex at `923d23f`, which pins aemi `04e49d1`, while FSCore pinned `785c6b2`, and resolution failed.

## Decision

Every MacFS package pins aemi at the same revision (`04e49d108e43a94fac449f344bfca9eabc5be0e9`), moved together. Used today: AemiKernel
(unaligned little-endian loads, checked arithmetic, XXH64 for Btrfs xxhash checksums), AemiIO (`PosixFile`), AemiRegex (repository
rules in Tooling), Aemi's `format` and `lint` plugins and the canonical `.swift-format` and `.swiftlint.yml`. Reserved: AemiProtobuf
for the proxy helper's IPC and AemiJSON for configuration and reports, when those exist; nothing is added before it is used.

## Consequences

`DiskBytes` wraps Aemi's loads with the bounds check they leave to the caller, because Aemi checks only in debug and disk bytes are
hostile. Info.plists are property lists, so `PropertyListSerialization` writes them, not a JSON library.
