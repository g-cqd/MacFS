---
status: open
blocked-by: []
date: 2026-10-30
---

# 0046 — Writes through every mount path

A format that can write is not a writable disk until the path that mounts it carries the writes; each is read-only today by decision
(ADR-0006, ADR-0010, 0008). Per path: FSKit (the volume's write, create, remove, rename and set-attribute operations, and the
kernel-offloaded write mapping), the NFS proxy (WRITE, CREATE, MKDIR, REMOVE, RENAME, SETATTR, and COMMIT with stable-storage
semantics), WebDAV (PUT, DELETE, MKCOL, MOVE, without the Finder sidecar files Everest answers 404), and File Provider (modify, create,
delete). Writable is opt-in per mount, shown in the mount sheet, and every path is checked by the format's own checker (0017's table)
after writes made through it.

## Progress

1. **FSKit, ext2 (2026-11-01):** a named mount writes (since step 3, only with `-o rw` or `writable`); an automount stays
   read-only. The module's generic volume begins the format's writer at activation (`WritableFileSystem.beginWriting`),
   answers every change through it (create, symlink, link, rename, remove, set attributes and size, write), maps writes for the
   kernel and completes them, synchronizes, and closes the writer at unmount. Live on a copy of the ext2 image: writes of 4 KiB
   to 4 MiB, a 3 MB copy byte for byte, create, append, mkdir, mv (a directory to another parent too), symlink, hard link, rm,
   truncate, chmod; then `e2fsck -fn` clean, and Linux's `debugfs` reads the files back. Not yet: the other paths.
2. **The live write check (2026-11-02):** `macfs-tool mounts` ends with each writable format's session (`WriteCheck`): a copy
   of the image with its own volume UUID, attached writable, mounted without `rdonly`, changed by commands with deadlines (a
   4 MiB + 1234 byte copy and `cmp`, mkdir, mv of a file and of a directory, symlink, link, rm, truncate, append, chmod),
   unmounted, detached, then on Linux `e2fsck -fn` and `debugfs` hashes of the files against the host's. Its first run found
   a lost append (next diary entry); 37 of 37 after the fix.
3. **The check, and writes by name (2026-11-02):** every module declares and runs a check (`fsck_fskit -t <type>`, and Disk
   Arbitration before mounting a writable device), read-only and format-generic (`VolumeCheck`, with each format's
   `consistencyProblems`; ext reads its superblock state). Disk Arbitration then mounts writable devices, so writes are asked for
   by name (`WriteRequest`: `rw` or `writable`). Live: DA with `writable` mounts a clean copy read-write; DA without it, an
   automount, and a not-clean copy (with or without) mount read-only; the mount check adds "automount refuses a write", 38 of
   38. Not yet: the app's "Mount writable" (0021's Disks section), the NFS proxy, WebDAV, File Provider.
4. **The NFS proxy answers changes (2026-11-02, library):** `NFSDispatcher` takes the volume's writer; with it, SETATTR (with
   its guard), WRITE (FILE_SYNC when asked, a per-server write verifier), CREATE (unchecked, guarded, exclusive with the
   verifier in the times), MKDIR, SYMLINK, REMOVE, RMDIR, RENAME, LINK and COMMIT go to it, and ACCESS grants modify, extend and
   delete; MKNOD is NFS3ERR_NOTSUPP. Without one, as before, NFS3ERR_ROFS. Tested over RPC on a copy of the ext2 image, then
   e2fsck.
5. **Writable proxy mounts (2026-11-02):** `MountRequest.writable` (the service's `mount(…, writable:)`) reaches the NFS backend,
   whose `open` returns the tree and, when asked and the format's writer began, the writer (`OpenedVolume`); the proxy then
   serves it, `mount_nfs` drops `rdonly` (and writes in 128 KiB), and the writer closes, the volume clean, after the proxy
   stops. `macfs-nfsd IMAGE --mount DIR --writable`. Live through macOS's NFS client: the write check's operations, then
   e2fsck clean and debugfs hashes identical. Its first run lost data silently (`cp` kept 917,504 of 4,195,638 bytes, exit 0):
   the client keeps several WRITEs in flight, and the ext writer's changes raced; they are serialized now (`changeLock`).
   Not yet then: the agent and the app (step 6). A soft mount may fail a WRITE when the proxy dies (ADR-0014's trade-off; the proxy lives in the same process).
6. **Through the agent and the app (2026-11-02):** the agent's request carries `writable` (protobuf field 7; absent is
   read-only), `AgentClient.mount(…, writable:)`, and `MacFS --mount-image PATH --writable` opens the image read-write and asks
   for it. `macfs-tool mounts` gains "agent, writable" (`AgentWriteCheck`): a fresh copy in the app's container, mounted by the
   installed app through its agent, the write check's operations, unmounted through the app, then e2fsck and debugfs: 39 of
   39. Its first run found the installer never restarted the agent (launchd starts it as `Contents/MacOS/macfs-agent`, and the
   stop pattern wanted a leading slash), so every install kept the old agent. Not yet: a "Mount writable" control in the window
   (0021's Disks section), WebDAV, File Provider.
