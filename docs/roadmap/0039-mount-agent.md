---
status: open
blocked-by: ["0035"]
date: 2026-10-30
---

# 0039 — A launchd agent owns proxy mounts

ADR-0013 #6. The app is sandboxed and cannot run `mount_nfs`; Everest, unsandboxed, hosts its server in the app, so its mounts die
with it. `macfs-agent`, registered with `SMAppService.agent`, hosts the NFS (and later WebDAV) servers, runs the mount commands,
keeps the registry (0035) and sweeps it at start; the app asks over XPC (AemiProtobuf). Mounts survive the app quitting. The status
pane reports the agent's registration and approval like the modules'.
