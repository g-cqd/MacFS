// The system zlib (libz): the codec tests make their streams with it and hold MacFS's decoder to it. Tests only.
#ifndef CODEC_ORACLE_H
#define CODEC_ORACLE_H

#include <stddef.h>
#include <stdint.h>

/// Raw DEFLATE of `source[0..<count]` by libz's deflate with these parameters (deflateInit2: level 0 to 9, window bits 9 to
/// 15 (raw: passed negated), memLevel 1 to 9, strategy 0 default, 1 filtered, 2 Huffman only, 3 RLE, 4 fixed), into
/// `target[0..<capacity]`. Returns the stream's length, or -1.
int64_t fsk_oracle_deflate(const uint8_t *_Nonnull source, size_t count, uint8_t *_Nonnull target, size_t capacity,
                           int level, int windowBits, int memLevel, int strategy);

/// The system libz's inflate of raw DEFLATE, one call with Z_FINISH, as Linux's btrfs reads zlib extents (fs/btrfs/zlib.c
/// skips the two-byte header and inflates with -MAX_WBITS; the Adler-32 trailer is not read): `fsk_inflate`'s reference.
/// Returns 0 when the stream ended or the target is full, -2 when the input ended first, -1 otherwise.
int32_t fsk_oracle_inflate(const uint8_t *_Nonnull source, size_t count, uint8_t *_Nonnull target, size_t capacity,
                           size_t *_Nonnull produced);

/// The most `fsk_oracle_deflate` can write for `count` bytes (deflateBound with the widest parameters, plus slack).
size_t fsk_oracle_deflate_bound(size_t count);

/// The number of hand-built streams `fsk_oracle_vector` makes.
unsigned fsk_oracle_vector_count(void);

/// Hand-built raw DEFLATE stream `which` (below `fsk_oracle_vector_count()`) into `target[0..<capacity]`: its length, or 0
/// when it does not fit. Each holds a rule libz's encoder never writes: flushed blocks, codes with no distance, lone 1-bit
/// codes, codes one 15-bit code short, too many code lengths, all of them, an all-zero precode, no end-of-block code, headers
/// at the input's end, distance codes 30 and 31, a full output before an error, 48-bit symbols, random deep codes. `*name`
/// says which; `*size` is the output it decodes to, or the capacity its rule needs.
size_t fsk_oracle_vector(unsigned which, uint8_t *_Nonnull target, size_t capacity, const char *_Nullable *_Nonnull name,
                         size_t *_Nonnull size);

#endif
