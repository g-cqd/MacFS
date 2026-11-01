---
status: in-progress
blocked-by: ["0035"]
date: 2026-10-30
---

# 0039 — A launchd agent owns proxy mounts

ADR-0013 #6. The app is sandboxed and cannot run `mount_nfs`; Everest, unsandboxed, hosts its server in the app, so its mounts die
with it. `macfs-agent`, registered with `SMAppService.agent`, hosts the NFS (and later WebDAV) servers, runs the mount commands,
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

Open: bundling the agent in the app (`Contents/Library/LaunchAgents`, `SMAppService.agent`), the app group entitlement, the status
pane's agent check, the app's mount action; and the image's path: an unsandboxed agent opening a file in Downloads or Documents
meets TCC, so the app should pass the open file (a descriptor or a bookmark), not its path.
