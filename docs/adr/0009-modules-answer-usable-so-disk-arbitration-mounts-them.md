---
status: accepted
supersedes: ["0006"]
date: 2026-10-30
---

# 0009 — Modules answer "usable", so Disk Arbitration mounts them

## Context

ADR-0006 had the modules answer probes with "usable but limited", read-only being a limitation. With the modules enabled, attaching
an image never mounted it. Disk Arbitration's log (`/usr/bin/log stream`, diary 2026-10-30-04) showed it asking our module, receiving
`Found usable but limited result`, and recording `unable to probe (status code 0xFFFFFFFA)`: that answer counts as a failure.

## Decision

A volume the reader opens is answered `usable` (`MountKit.ProbeAnswer`, tested); read-only is carried by the mount options
(`requestedMountOptions = .readOnly`), which every mount showed. Everything else in ADR-0006 stands: one module per format, short
names `btrfs`, `ext4`, `ntfsro` that shadow nothing, plists generated from `DiskFormat`, ownership ignored, `DiskError`.

## Evidence

Plain `hdiutil attach -readonly` now mounts `/Volumes/<label>` through our modules for partitionless Btrfs and ext images and for a GPT
partition of type "Linux filesystem"; each tree matched its manifest. NTFS images are claimed first by macOS's own `ntfs` module, which
mounts them read-only itself; `ntfsro` is reached with `mount -F -t ntfsro`.

## Consequences

Plugged-in Linux disks mount on their own. Which module wins for NTFS is the system's choice; making ours preferred is not attempted.
