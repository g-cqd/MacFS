// Raw DEFLATE through the system zlib (libz): Btrfs's zlib extents, decoded as Linux decodes them (fs/btrfs/zlib.c checks the
// two-byte header, then inflates with -MAX_WBITS, so the Adler-32 trailer is not read). The system libz decodes these extents
// at twice the speed of Compression.framework's COMPRESSION_ZLIB on this machine (docs/conformance/performance.md).
#include "fskernels.h"

#include <zlib.h>

int32_t fsk_zlib_inflate(const uint8_t *source, size_t count, uint8_t *target, size_t capacity, size_t *produced) {
    *produced = 0;
    if (count > UINT32_MAX || capacity > UINT32_MAX) return -1;
    z_stream stream = {0};
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return -1;
    stream.next_in = (Bytef *)source;
    stream.avail_in = (uInt)count;
    stream.next_out = target;
    stream.avail_out = (uInt)capacity;
    int status = inflate(&stream, Z_FINISH);
    *produced = capacity - stream.avail_out;
    inflateEnd(&stream);
    // The end of the stream, or a full output (an extent decodes to at most its declared size): both are a result.
    if (status == Z_STREAM_END || (status == Z_BUF_ERROR && stream.avail_out == 0)) return 0;
    return status == Z_BUF_ERROR ? -2 : -1;  // -2: the stream ended early (truncated input)
}
