---
status: accepted
supersedes: ["0013"]
date: 2026-11-01
---

# 0016 — Mounts go through one seam, and a sandboxed agent owns proxy mounts

## Context

ADR-0013 put every mount behind one seam and gave proxy mounts to a launchd agent, unsandboxed so it could run `mount_nfs`.
Registering that agent from the sandboxed app failed: background task management answered "SMAppService target executable must
be sandboxed because the app is sandboxed" (diary 2026-11-01-04). A bare command-line tool cannot be sandboxed either (the
sandbox traps at launch without an Info.plist in the binary). Measured then: a sandboxed agent, its Info.plist embedded, registered
by the app, runs `mount_nfs` and mounts an image the app sent as a descriptor.

## Decision

ADR-0013 stands (one seam, no silent substitution, a persisted registry, make before break, soft proxy mounts, the lifecycle in
TLA+), with decision 6 replaced:

6. **Proxy mounts belong to a sandboxed launch agent**, `macfs-agent` in `Contents/MacOS`, registered by the app with
   `SMAppService.agent` from `Contents/Library/LaunchAgents`. Its entitlements: the App Sandbox, network server and client
   (loopback), the app's group. It is reached over XPC at `<team-id>.dev.gcqd.MacFS.agent`; both ends require a peer of the same
   team. The app opens the image the user chose and sends its descriptor; the agent reads through it and never opens the path.
   Its registry and its mount points live in its container (`~/Library/Containers/dev.gcqd.MacFS.agent`).

## Consequences

Both processes are sandboxed: the agent can reach nothing the user did not hand the app. Mount points sit in the agent's
container, a long path; Finder lists the mounts as network volumes. Scripted checks use `MacFS --register-agent`,
`--mount-image PATH`, `--list-mounts` and `--unmount ID`, launched through `open` so LaunchServices starts the app.
