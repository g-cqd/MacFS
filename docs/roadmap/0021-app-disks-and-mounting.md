---
status: open
blocked-by: []
date: 2026-10-30
---

# 0021 — The app finds disks and mounts them

Revised after the probes in `docs/research/2026-11-01-disks-from-the-app.md`: macOS already mounts our formats when a disk is
attached, through our FSKit modules, and Disk Arbitration's own API mounts, unmounts and ejects them from a sandboxed process. No
raw device access, no `authopen`.

1. **Disks in the app:** a `DiskKit` target with a Disk Arbitration watcher (appeared, changed, disappeared) and a pure model of a
   disk's description: whole or partition, size, removable, its volume (kind, name, path), and whether MacFS reads it (one of our
   module short names) or might (a Linux partition type, not mounted, no file system macOS knows). The model is tested on
   recorded descriptions; the watcher live on attached images.
   **Done:** `DiskKit` (`DiskDescription`, `DiskValue`, `DiskList`, `DiskWatcher`). The model is tested on 24 descriptions recorded
   from the test images, exFAT, APFS (the synthesized container and the physical disk) and a Linux partition with its superblock
   zeroed (`Tests/DiskKitTests/Recorded.json`, read with AemiJSON). Who reads it comes from the volume kind macOS found by probing;
   without one, "not a leaf" is a container (a GPT disk, the APFS physical partition and container), and a Linux partition type
   might be ours. The watcher, live: an image attached, automounted by our module in 0.7 s (appeared, then changed with its path),
   detached (disappeared); a stopped watcher reports nothing for an image attached after. Not yet in the app (step 2).
2. **Actions through Disk Arbitration:** mount, unmount and eject, as `DADiskMount`, `DADiskUnmount` and `DADiskEject`, with the
   dissenter's status turned into a message. The app's window gains a Disks section beside Mounts.
3. **The `mounts` check covers the disk path:** each image attached, automounted by macOS, unmounted and remounted through
   `DiskKit`, compared with its manifest, then ejected.
4. **Image mounts through FSKit path resources** (research conclusion 4): the modules accept `FSPathURLResource`, the app mounts an
   image with `FSClient.mountSingleVolume`, as a `MountBackend` beside NFS. It needs its own probe and ADR.
5. **`diskutil` and StorageKit:** find what they need to know a third-party FSKit volume (an `.fs` bundle?).
