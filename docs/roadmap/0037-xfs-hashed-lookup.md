---
status: done
blocked-by: ["0031"]
date: 2026-10-30
---

# 0037 — XFS hashed directory lookup

Look a name up as the kernel's `xfs_dir_lookup` does, instead of scanning a listing built from every data block: the name's
`xfs_da_hashname`, the hash leaf entries (the block's tail, a `LEAF1` block, or the `LEAFN` leaves under a `DA3N` node tree), and
only the data entries they address. Research 2026-10-30-compression-kernels ("Next").

## Done

`XFSDirectoryHash` (the kernel's hash), `XFSFileSystem+HashedLookup` (form by the data fork's end as `xfs_dir2_format` tells it;
node descent as `xfs_da3_node_lookup_int`; the next leaf while a hash run reaches a leaf's end, as `xfs_da3_path_shift`), every da
block's magic, CRC and owner checked, read blocks in a bounded cache. ASCII case-insensitive volumes (`-n version=ci`, deprecated,
refused by the reference kernel) are refused by name.

References: xfs_db `hash` for 91 names (`xfshash.txt`); two images written by the kernel holding block, leaf (with stale entries),
node and level-2 node directories, and 1,080 names of one hash across leaves (`Scripts/xfs-names.c`), each name and inode
the kernel made in `.names` (227,423 and 5,393). docs/conformance/xfs.md, docs/conformance/performance.md.

Known regression: a run of one hash across many entries costs a data entry per candidate, as in the kernel; the adversarial
`collide` directory looks up 13 times slower than the old scan of a cached listing.

"." and ".." are not entries, in any form. Each check of the lookup has a damage test (one block changed, its CRC recomputed).
`macfs-tool images --mirror HOST` builds the images from an Alpine mirror when the CDN crawls.

Not done: the da blocks' `blkno` and uuid are not checked, nor the leaf's hash order.
