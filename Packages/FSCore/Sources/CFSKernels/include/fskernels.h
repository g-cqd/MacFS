// Hot loops shared by the file system readers. On arm64 they are hand-written assembly
// (kernels_arm64.S: the CRC extension, PMULL and NEON); elsewhere portable C (kernels_portable.c).
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

/// CRC-32C (Castagnoli), reflected, with no pre- or post-inversion: the caller chooses the
/// seed and the final xor. Btrfs checksums use seed ~0 and invert the result; its name hash
/// uses seed ~1 and does not invert.
uint32_t fsk_crc32c_update(uint32_t crc, const uint8_t *_Nullable bytes, size_t count);

/// Undoes the NTFS update sequence array of one multi-sector record in place.
/// Returns 0 when every stride ended with the update sequence number, -1 when the header is
/// malformed for `size` and `stride`, -2 when a stride's last two bytes did not match (a torn
/// write). On -2 the record is partially restored and must be discarded.
int32_t fsk_ntfs_apply_fixups(uint8_t *_Nonnull record, size_t size, size_t stride);

/// Number of set bits in `count` bytes.
uint64_t fsk_popcount(const uint8_t *_Nullable bytes, size_t count);

/// Narrows UTF-16LE code units (`count` units, `2 * count` bytes, any alignment) to ASCII bytes
/// while they are below 0x80. Returns how many units were copied into `ascii` (which must hold
/// `count` bytes); the first unit not copied is either non-ASCII or past the end.
size_t fsk_utf16le_ascii_prefix(const uint8_t *_Nullable units, size_t count, uint8_t *_Nullable ascii);

/// Block size and block count of the disk device open on `fd` (DKIOCGETBLOCKSIZE and
/// DKIOCGETBLOCKCOUNT, whose ioctl macros Swift cannot import). Returns 0, or -1 with errno set.
int32_t fsk_device_geometry(int32_t fd, uint32_t *_Nonnull blockSize, uint64_t *_Nonnull blockCount);

#ifdef __cplusplus
}
#endif

#endif
