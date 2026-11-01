---
status: accepted
date: 2026-11-01
---

# 0015 — The mount registry and the agent's messages are protobuf, in a checked envelope

## Context

ADR-0013 makes a persisted registry the truth about mounts and gives proxy mounts to an agent that talks to the app. Both cross
versions: a registry file outlives the app that wrote it, and an updated app talks to the previous agent until launchd restarts
it. ADR-0004 reserved AemiProtobuf for IPC and AemiJSON for configuration. AemiProtobuf now pins the family's aemi (`7b7dbc5`).
Research 2026-11-01-registry-and-ipc-encoding measured protobuf, a property list and AemiJSON on the registry's records.

## Decision

1. **Protobuf for both**, through AemiProtobuf's `@ProtoMessage`, one schema for the registry and the messages. Field numbers are
   never reused; a removed field's number is reserved in a comment.
2. **An envelope around every registry file**: magic `MFSR`, a format version, the message length, then the message and its
   CRC-32C. A file that fails any check is moved aside (`.corrupt-<date>`) and reported, never half-read. Writes go to a temporary
   file, are `fsync`ed, then renamed over the registry.
3. **Open enums** for backend kinds and states. A record or message carrying a value this version does not know is kept and
   reported, and nothing acts on it: no unmount routed, no sweep.
4. **Not in `MountKit`**: the seam's store is a protocol there. The protobuf store and messages live in their own target, linked by
   the app and the agent only, never by the FSKit extensions.
5. XPC carries the encoded bytes (`XPCSession`); its own `Codable` is not used for the messages, as it has the version-skew
   faults the research measured.

## Consequences

A clean build of the app and the agent gains swift-syntax (about 200 s once), and they gain about 0.6 MB. Diagnostics print a
registry through AemiProtobuf's JSON mapping, because the file is not human-readable. AemiProtobuf joins the one-pin rule
(ADR-0004): it moves with aemi and AemiJSON. Nothing is added to `Package.swift` until 0035's store uses it.
