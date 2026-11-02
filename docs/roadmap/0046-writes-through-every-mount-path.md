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
