---
status: open
blocked-by: []
date: 2026-10-30
---

# 0030 — Use the kernels promoted into aemi

aemi ADR 0020 (branch `macfs-kernels`, commits `bd1838e` and `08e1fa3`, not yet published) carries CRC-32C, the buffer bit count and
the UTF-16LE ASCII prefix. Once the owner publishes it and AemiRegex accepts the same aemi revision (one pin, ADR-0004): move the pin,
replace `BitCount` and `UTF16Name`'s kernel with `AemiKernels.bitCount` and `asciiPrefix`, and measure whether MacFS's assembly CRC
(58.7 GB/s) still earns its place over aemi's intrinsics (52.2 at `-Os`); drop it if the difference does not show in a reader.

Other candidates read and not moved, each for a stated reason: `DiskBytes` (aemi has `CheckedBytes` since its ADR 0018: the move is
the other way, MacFS adopting it if its throwing checks fit), `BoundedCache` (no second consumer named yet), `AlignedReader` (raw
devices only; a second consumer would put it in AemiIO), the Tooling rules (the family's own gates live per repository today).
