# NTFS

| Reference | How |
|---|---|
| ntfs-3g 2026.2.25 (FUSE) | The image is written by ntfs-3g from the full test tree, and `NTFSConformanceTests` compares every node with ntfs-3g's view: type, link count, size, directory size, mtime, ctime (100 ns), content. Modes and owners are ntfs-3g's mount options, not NTFS data, so not compared |
| [MS-FSCC], ntfs-3g's `ntfs_get_interix_type` | Reparse-point links (symlink, junction, WSL) and Interix links (`IntxLNK`, what ntfs-3g writes): `NTFSInterixTests` |

Found by the reference: ntfs-3g writes symlinks as Interix system files, which read as 32-byte files until they were decoded; a
directory's size is its `$I30` index allocation's data size, 0 when the index fits in its root.

No reference test suite exists for NTFS images (ntfs-3g ships none). Open: LZNT1-compressed streams (roadmap 0014), Interix
device and FIFO tags (read as files).
