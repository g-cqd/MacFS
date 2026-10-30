// The portable kernels for targets without kernels_arm64.S (x86_64), and the references the arm64 kernels are tested
// against: built on every target as fsk_ref_ntfs_apply_fixups and fsk_ref_lznt1_decompress.
#include "fskernels.h"

int32_t fsk_ref_ntfs_apply_fixups(uint8_t *record, size_t size, size_t stride);
int32_t fsk_ref_lznt1_decompress(const uint8_t *source, size_t count, uint8_t *target, size_t capacity);

static uint16_t load16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }

int32_t fsk_ref_ntfs_apply_fixups(uint8_t *record, size_t size, size_t stride) {
    if (size < 8 || stride < 2) return -1;
    size_t offset = load16(record + 4), entries = load16(record + 6);
    if (entries == 0 || (offset & 1u) || size % stride != 0) return -1;
    if (entries - 1 != size / stride || offset + entries * 2 > size) return -1;
    uint16_t usn = load16(record + offset);
    for (size_t i = 1; i < entries; i++) {
        uint8_t *tail = record + i * stride - 2;
        if (load16(tail) != usn) return -2;
        tail[0] = record[offset + 2 * i];
        tail[1] = record[offset + 2 * i + 1];
    }
    return 0;
}

// LZNT1, byte by byte: the reference for the arm64 kernel (ntfs-3g's ntfs_decompress, every bound checked).
int32_t fsk_ref_lznt1_decompress(const uint8_t *source, size_t count, uint8_t *target, size_t capacity) {
    size_t position = 0, chunk = 0;
    while (position + 2 <= count && chunk < capacity) {
        size_t header = load16(source + position);
        if (header == 0) break;
        size_t end = position + (header & 0x0FFF) + 3, limit = chunk + 4096;
        if (end > count || limit > capacity) return -1;
        position += 2;
        size_t written = chunk;
        if (!(header & 0x8000)) {
            if (end - position != 4096) return -1;
            for (size_t i = 0; i < 4096; i++) target[chunk + i] = source[position + i];
            written = limit;
        } else {
            while (position < end) {
                unsigned flags = source[position++];
                for (int token = 0; token < 8 && position < end; token++, flags >>= 1) {
                    if (!(flags & 1)) {
                        if (written >= limit) return -1;
                        target[written++] = source[position++];
                        continue;
                    }
                    if (position + 2 > end) return -1;
                    size_t value = load16(source + position);
                    position += 2;
                    unsigned shift = 0;
                    for (size_t reach = written - chunk - 1; written > chunk && reach >= 0x10; reach >>= 1) shift++;
                    size_t distance = (value >> (12 - shift)) + 1, length = (value & (0x0FFFu >> shift)) + 3;
                    if (distance > written - chunk || length > limit - written) return -1;
                    for (size_t i = 0; i < length; i++, written++) target[written] = target[written - distance];
                }
            }
        }
        while (written < limit) target[written++] = 0;
        position = end;
        chunk = limit;
    }
    while (chunk < capacity) target[chunk++] = 0;
    return 0;
}

#if !defined(__aarch64__)
int32_t fsk_lznt1_decompress(const uint8_t *source, size_t count, uint8_t *target, size_t capacity) {
    return fsk_ref_lznt1_decompress(source, count, target, capacity);
}

int32_t fsk_ntfs_apply_fixups(uint8_t *record, size_t size, size_t stride) {
    return fsk_ref_ntfs_apply_fixups(record, size, stride);
}
#endif
