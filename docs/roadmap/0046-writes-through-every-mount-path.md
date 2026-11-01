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

1. **FSKit, ext2 (2026-11-01):** a named mount without `rdonly` (`mount -F -t ext4 /dev/diskN point`) writes; an automount
   stays read-only. The module's generic volume begins the format's writer at activation (`WritableFileSystem.beginWriting`),
   answers every change through it (create, symlink, link, rename, remove, set attributes and size, write), maps writes for the
   kernel and completes them, synchronizes, and closes the writer at unmount. Live on a copy of the ext2 image: writes of 4 KiB
   to 4 MiB, a 3 MB copy byte for byte, create, append, mkdir, mv (a directory to another parent too), symlink, hard link, rm,
   truncate, chmod; then `e2fsck -fn` clean, and Linux's `debugfs` reads the files back. Not yet: the FSKit check (for Disk
   Arbitration's writable mounts and the app's "Mount writable"), a live check in `macfs-tool mounts`, the other paths.
