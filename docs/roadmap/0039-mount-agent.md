---
status: in-progress
blocked-by: ["0035"]
date: 2026-10-30
---

# 0039 — A launchd agent owns proxy mounts

ADR-0016 (superseding ADR-0013 #6). Everest hosts its server in the app, so its mounts die with it; a proxy mount must outlive the
app, so its server lives in an agent. `macfs-agent`, registered with `SMAppService.agent`, hosts the NFS (and later WebDAV) servers, runs the mount commands,
keeps the registry (0035) and sweeps it at start; the app asks over XPC (AemiProtobuf). Mounts survive the app quitting. The status
pane reports the agent's registration and approval like the modules'.

## Progress

Built, red first: the protocol in `MountAgent` (protobuf `AgentRequest`/`AgentReply`, `AgentDispatcher` over `MountService`,
`AgentClient` over any byte transport; unknown operations refused by number, every `MountError` crossing intact), and
`macfs-agent`: an `XPCListener` on `NP94WB3P75.dev.gcqd.MacFS.agent` (the app group as prefix, which a sandboxed app may look up)
that accepts only peers of the same team, sweeping its registry at start, and a `call` client. Checked live through launchd: a mount
outlives the client that asked for it; an ad-hoc-signed client is refused; after `kill -9` the next call starts a new agent whose
sweep unmounts the dead proxy's mount.

Each owner has its own registry (`registry.pb` for the agent, `registry-cli.pb` for `macfs-nfsd --mount`): a sweep unmounts what
its process does not serve, so two owners of one registry would unmount each other.

In the app (ADR-0016): `macfs-agent` in `Contents/MacOS`, its plist in `Contents/Library/LaunchAgents`, registered with
`SMAppService.agent`; sandboxed, because a sandboxed app may register nothing else; the app group for the Mach service. The app
opens the image the user chose and sends the descriptor (XPC duplicates it); the agent reads through it and picks the mount point in
its container. The status pane has the agent's line (registered, waiting for approval, missing) with its remedy; the window has
Mount and a Mounts list with Unmount. Checked live through the installed app: registration, a mount of an image in the app's
container (unreadable to the agent by path), the mount read against the reference manifest after the app quit, an unmount.

Open: a repeatable check of agent mounts in the `mounts` plugin; mount points outside the agent's container.
