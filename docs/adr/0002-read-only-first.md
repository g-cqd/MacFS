---
status: accepted
date: 2026-10-30
---

# 0002 — Read-only first

## Context

Writing Btrfs means copy-on-write trees, checksums and space accounting; NTFS means `$LogFile`, `$Bitmap`, indexes and security; ext4
means the journal. A write path with a bug corrupts a user's disk; a read path with a bug returns an error.

## Decision

Every reader is read-only by construction: no write code exists. Every module requests a read-only mount and answers every mutating
operation `EROFS`. Writes are planned per format (roadmap 0017), each with its own crash-consistency design and its own ADR.

## Consequences

Reads never mutate state on disk, so they can be retried and run concurrently. Users who need writes keep their current tools until 0017.
