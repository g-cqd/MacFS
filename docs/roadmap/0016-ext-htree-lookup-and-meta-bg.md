---
status: done
blocked-by: []
date: 2026-10-30
---

# 0016 — ext htree hashed lookup, and meta_bg

Lookup by hash (half-MD4, TEA) instead of a cached linear scan; group descriptors under meta_bg (refused today).

## Done

Lookup by hash through the index (`ExtFileSystem+Htree.swift`, `ExtDirectoryHash.swift`), as `dx_probe` does it: half-MD4,
TEA and the legacy hash, signed or unsigned by `s_flags`, seeded by `s_hash_seed`; continuation into the next leaf for a split
collision; an index the kernel would call bad is scanned instead. Index blocks verify their `dx_tail` (`ext4_dx_csum`), leaves
their tail, told apart by position. meta_bg (`ExtSuperblock.DescriptorLayout`: `ext4_bg_has_super`, `descriptor_loc`, with
sparse_super, sparse_super2 and the 1 KiB bigalloc case). Oracles: e2fsprogs' `dx_hash` (900 hashes), two new images (meta_bg
without sparse_super; a volume the kernel grew online into meta_bg and filled itself, with a two-level htree of 10,000 names),
ext3 hashing with TEA, ext4-uuid-seed with the legacy hash, ext4-bigalloc signed, and the kernel's view of each image.
