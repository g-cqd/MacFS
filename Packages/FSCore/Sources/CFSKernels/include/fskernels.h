// The format-specific kernel of the readers, and the device ioctls Swift cannot import. The fixups are hand-written arm64
// assembly (kernels_arm64.S), portable C elsewhere (kernels_portable.c); the generic kernels (CRC-32C, bit counts, UTF-16
// narrowing) are aemi's (ADR-0012).
// Every function here is pure: it reads and writes only through the pointers it is given,
// within the lengths it is given, and keeps no state. The Swift wrappers in FSCore check
// the results (ADR-0003).
#ifndef FSKERNELS_H
#define FSKERNELS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif


/// Undoes the NTFS update sequence array of one multi-sector record in place.
/// Returns 0 when every stride ended with the update sequence number, -1 when the header is
/// malformed for `size` and `stride`, -2 when a stride's last two bytes did not match (a torn
/// write). On -2 the record is partially restored and must be discarded.
int32_t fsk_ntfs_apply_fixups(uint8_t *_Nonnull record, size_t size, size_t stride);



/// Block size and block count of the disk device open on `fd` (DKIOCGETBLOCKSIZE and
/// DKIOCGETBLOCKCOUNT, whose ioctl macros Swift cannot import). Returns 0, or -1 with errno set.
int32_t fsk_device_geometry(int32_t fd, uint32_t *_Nonnull blockSize, uint64_t *_Nonnull blockCount);

#ifdef __cplusplus
}
#endif

#endif
