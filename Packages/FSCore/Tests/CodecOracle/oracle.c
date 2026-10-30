// The codec tests' references (codec_oracle.h), through the system libz. Tests only.
#include "codec_oracle.h"

#include <zlib.h>

int64_t fsk_oracle_deflate(const uint8_t *source, size_t count, uint8_t *target, size_t capacity, int level,
                           int windowBits, int memLevel, int strategy) {
    if (count > UINT32_MAX || capacity > UINT32_MAX) return -1;
    z_stream stream = {0};
    if (deflateInit2(&stream, level, Z_DEFLATED, -windowBits, memLevel, strategy) != Z_OK) return -1;
    stream.next_in = (Bytef *)source;
    stream.avail_in = (uInt)count;
    stream.next_out = target;
    stream.avail_out = (uInt)capacity;
    int status = deflate(&stream, Z_FINISH);
    int64_t length = (int64_t)(capacity - stream.avail_out);
    deflateEnd(&stream);
    return status == Z_STREAM_END ? length : -1;
}

size_t fsk_oracle_deflate_bound(size_t count) { return count + count / 8 + 1024; }

int32_t fsk_oracle_inflate(const uint8_t *source, size_t count, uint8_t *target, size_t capacity, size_t *produced) {
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
