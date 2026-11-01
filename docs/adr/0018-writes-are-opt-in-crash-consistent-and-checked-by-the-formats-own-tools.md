---
status: accepted
date: 2026-11-01
---

# 0018 — Writes are opt-in, crash-consistent by each format's own mechanism, and checked by each format's own tools

## Context

The owner's requirement is writable disks on every format MacFS reads: ext2/3/4, NTFS, Btrfs and XFS (roadmap 0017). Today every
reader sits behind `ReadOnlyFileSystem`, and every mount path answers EROFS to every change (ADR-0006, ADR-0010). A writer that
corrupts a volume is worse than none: the volumes are users' Linux and Windows disks, and the other operating system must
still accept them afterwards.

Measured on macOS 27 (diary 2026-11-01-11, the installed ext module, a writable image):

- FSKit loads the module with a writable device (`FSBlockDeviceResource.isWritable`) for a mount without `rdonly`, and mounts the
  volume read-write as soon as the volume stops answering `requestedMountOptions: .readOnly`. Writes then reach the module.
- Disk Arbitration automounts these volumes read-only by itself (`-o …,rdonly`): the default needs nothing from us.
- `DADiskMount` of a writable device first runs the module's FSKit check (`FSManageableResourceMaintenanceOperations`), which
  the modules lack; Disk Arbitration then refuses the mount (ENOTSUP). A real check is therefore part of the write path.
- FSKit's device offers synchronous `write(from:startingAt:length:)`, metadata writes through the kernel buffer cache, and
  `metadataFlush()`.
- The container that builds the test images already carries every format's checker: `e2fsck`, `xfs_repair`, `btrfs check`,
  `ntfsfix`.

## Decision

1. **One seam for writes.** `WritableFileSystem` refines `ReadOnlyFileSystem` with the changes the mount paths need: create
   (file, directory, symbolic link, device nodes where the format has them), write, set size, set attributes (mode, owner, times),
   remove, rename (with replace), hard link, and `synchronize`. A mount path writes only through it; nothing below it knows which
   path asked. Below it, `WritableBlockSource` refines `BlockSource` with `write(at:_:)` and `flush()`. `flush` is a barrier:
   everything written before it is durable once it returns. Writes between two flushes may land in any order, or not at all.
2. **Crash consistency is the format's own, never weaker.** After a power loss at any point, the volume must be one its own
   operating system accepts, after its own recovery:
   - ext3/ext4 with a journal: every metadata change goes through jbd2 transactions in ordered mode. Data blocks are flushed
     before the commit that references them, and commits carry checksums where the volume has them. Our reader replays a
     committed journal; a volume whose journal needs recovery is replayed before any write.
   - ext2, or ext without a journal: Linux's own model. The superblock is marked not clean while the volume is mounted writable
     and clean on unmount. A crash leaves a volume `e2fsck` must see, so MacFS refuses to write a volume that is not clean.
     Changes are ordered so that `e2fsck -p` (preen) repairs every crash state, measured state by state. The exception is a
     directory moved to another parent, or renamed outside its block: no order avoids two names or a stale `..` for a moment,
     and those states need `e2fsck -fy`, as on Linux's ext2.
   - XFS: changes go through the log as transactions, checkpointed, with CRCs. A volume whose log is dirty is refused for writing
     until it is replayed (by our replay once it exists, or by Linux).
   - Btrfs: copy-on-write. Live metadata is never overwritten. A transaction writes new tree blocks, flushes, then writes the
     superblocks with the new generation, flushing again.
   - NTFS: the ntfs-3g model, stated as it is. No `$LogFile` transactions; a volume whose `$LogFile` is not clean, or that is
     hibernated or marked dirty, is refused. The volume is marked dirty while mounted writable and clean on unmount, so after a
     crash Windows runs chkdsk. NTFS writes are consistent at unmount, not at every instant; the user is told so where writable
     is offered.
3. **Read-only by default, writable by asking.** A volume mounts writable only when all hold:
   - the mount was asked for writable: a named mount without `rdonly`, the app's "Mount writable", or a proxy mount's writable
     option;
   - the device is writable;
   - the format's writer is enabled for this release;
   - no refusal applies.

   Otherwise the volume mounts read-only and says why, in the module's log and in the app; asking for writable is never a reason
   to fail the mount. macOS's automount stays read-only.
4. **Refusals are named.** Each format's writer lists what it does not maintain and refuses those volumes by name, among them:
   an incompatible feature it does not know, an ext4 journal needing recovery, an XFS dirty log, a realtime XFS volume, a Btrfs
   volume on several devices, an NTFS volume hibernated or dirty. The FSKit check reports the same refusals, so Disk Arbitration
   and the module agree.
5. **The oracle is the format's own checker, after every test.** Every write test ends with that format's tool, in the container
   that builds the images: `e2fsck -fn`, `xfs_repair -n`, `btrfs check --readonly`, `ntfsfix -n` (and `chkdsk` where a Windows
   VM exists). The resulting tree is also compared with the expected one, through our reader and through the Linux tools. A
   checker's complaint fails the test, warnings included.
6. **Crashes are tested, not argued.** A recording `WritableBlockSource` logs every write and flush of a test. Each crash state
   is replayed onto a copy of the image:
   - every prefix that ends at a flush;
   - within the last unflushed epoch, a bounded set of subsets and reorderings.

   Each crash state must pass the format's checker after the format's own recovery. Its metadata must read as either the state
   before the operation or the one after it, never anything else. File data written since the last flush may hold any mix of
   old and new blocks, as on Linux. NTFS: anything chkdsk repairs without losing data written before the last clean unmount.
   Two invariants are checked on every state: no change is on disk without the mount recorded, and the volume never says
   clean before every change has landed. A journaled format's commit protocol is also modelled in TLA+ and checked by TLC before its code is
   written.
7. **Order.** ext2 first (the smallest writer, no journal), then ext4's journal, then XFS, Btrfs and NTFS. FSKit first among the
   mount paths, then the NFS proxy (WRITE, COMMIT with stable semantics), WebDAV and File Provider (roadmap 0046). Each format
   ships writable only when its oracle and crash tests pass on every test image of that format.

## Consequences

Writes come one format at a time, each behind its oracle; a format without one stays read-only. The FSKit check becomes real
code, needed for Disk Arbitration mounts and useful by itself (it can report a volume Linux should check). NTFS's guarantee is
weaker than the others' and is named as such. The crash explorer and the container checker are shared by every format, built
once with ext2. Apple's msdos module declares its check with `FSCheckOptionSyntax`; whether FSKit then calls ours is still to
be probed, on a fresh FSKit agent (the first attempt ran on a stale one).
