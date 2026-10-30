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



/// Decodes one LZNT1 compression unit ([MS-XCA] 2.5; NTFS compressed streams, roadmap 0014): `source[0..<count]` into
/// exactly `target[0..<capacity]`, every byte written. Chunks decode into 4 KiB each; a chunk that decodes short is zero-filled
/// to its 4 KiB, and the unit past its last chunk (a zero header, or the input's end) is zero. Returns 0, or -1 when a chunk
/// overruns its input or the unit, a stored chunk is not 4,096 bytes, or a phrase reaches before its chunk, past its 4 KiB or
/// past the chunk's input. The arm64 kernel and the portable C one (`fsk_ref_lznt1_decompress`) agree byte for byte.
int32_t fsk_lznt1_decompress(const uint8_t *_Nonnull source, size_t count, uint8_t *_Nonnull target, size_t capacity);

/// Decodes one LZO1X stream (as Linux's `lzo1x_decompress_safe`; Btrfs LZO segments) from `source[0..<count]` into
/// `target[0..<capacity]`. Returns the number of bytes decoded, or -1 when the stream is malformed, ends early, or would write
/// past `capacity` or copy from before the start. Bytes of `target` past the returned count are unspecified (the kernel's
/// word moves may run past a copy, never past `capacity`). The arm64 kernel and `fsk_ref_lzo1x_decompress` agree on every
/// result and every byte up to it.
int64_t fsk_lzo1x_decompress(const uint8_t *_Nonnull source, size_t count, uint8_t *_Nonnull target, size_t capacity);

/// Decodes the zstd frame at the start of `source[0..<count]` (RFC 8878; Btrfs zstd extents, roadmap 0013) into
/// `target[0..<capacity]`, with `workspace` (`fsk_zstd_workspace_size()` bytes, any contents) for its literals and tables.
/// Returns the bytes decoded and sets `*consumed` to the frame's length (bytes after it, such as a sector's padding, are not
/// read); 0 for a skippable frame. Bytes of `target` past the returned count are unspecified (16-byte moves may run past a
/// copy, never past `capacity`). -1 when the frame is malformed, its checksum differs, or it would write past `capacity`;
/// -2 when it needs a dictionary.
int64_t fsk_zstd_decompress_frame(const uint8_t *_Nonnull source, size_t count, uint8_t *_Nonnull target, size_t capacity,
                                  void *_Nonnull workspace, size_t *_Nonnull consumed);
size_t fsk_zstd_workspace_size(void);
/// XXH64 with seed 0 (the zstd content checksum's hash).
uint64_t fsk_xxh64(const uint8_t *_Nonnull bytes, size_t count);

/// Inflates raw DEFLATE (`source[0..<count]`, after a zlib header the caller has checked) into `target[0..<capacity]`
/// through the system libz; `*produced` is the number of bytes written. Returns 0 when the stream ended or the target is full,
/// -2 when the input ended first, -1 on a malformed stream.
int32_t fsk_zlib_inflate(const uint8_t *_Nonnull source, size_t count, uint8_t *_Nonnull target, size_t capacity,
                         size_t *_Nonnull produced);
/// Block size and block count of the disk device open on `fd` (DKIOCGETBLOCKSIZE and
/// DKIOCGETBLOCKCOUNT, whose ioctl macros Swift cannot import). Returns 0, or -1 with errno set.
int32_t fsk_device_geometry(int32_t fd, uint32_t *_Nonnull blockSize, uint64_t *_Nonnull blockCount);

#ifdef __cplusplus
}
#endif

#endif
