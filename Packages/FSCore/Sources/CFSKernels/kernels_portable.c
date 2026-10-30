// Portable versions of fskernels.h for targets without kernels_arm64.S (x86_64). They are also
// the reference the arm64 kernels are tested against: built on every target as fsk_ref_*.
#include "fskernels.h"

uint32_t fsk_ref_crc32c_update(uint32_t crc, const uint8_t *bytes, size_t count);
int32_t fsk_ref_ntfs_apply_fixups(uint8_t *record, size_t size, size_t stride);
uint64_t fsk_ref_popcount(const uint8_t *bytes, size_t count);
size_t fsk_ref_utf16le_ascii_prefix(const uint8_t *units, size_t count, uint8_t *ascii);

uint32_t fsk_ref_crc32c_update(uint32_t crc, const uint8_t *bytes, size_t count) {
    for (size_t i = 0; i < count; i++) {
        crc ^= bytes[i];
        for (int bit = 0; bit < 8; bit++) {
            crc = (crc >> 1) ^ ((crc & 1u) ? 0x82F63B78u : 0u);
        }
    }
    return crc;
}

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

uint64_t fsk_ref_popcount(const uint8_t *bytes, size_t count) {
    uint64_t total = 0;
    for (size_t i = 0; i < count; i++) total += (uint64_t)__builtin_popcount(bytes[i]);
    return total;
}

size_t fsk_ref_utf16le_ascii_prefix(const uint8_t *units, size_t count, uint8_t *ascii) {
    size_t i = 0;
    for (; i < count && load16(units + 2 * i) < 0x80; i++) ascii[i] = units[2 * i];
    return i;
}

#if !defined(__aarch64__)
uint32_t fsk_crc32c_update(uint32_t crc, const uint8_t *bytes, size_t count) {
    return fsk_ref_crc32c_update(crc, bytes, count);
}
int32_t fsk_ntfs_apply_fixups(uint8_t *record, size_t size, size_t stride) {
    return fsk_ref_ntfs_apply_fixups(record, size, stride);
}
uint64_t fsk_popcount(const uint8_t *bytes, size_t count) { return fsk_ref_popcount(bytes, count); }
size_t fsk_utf16le_ascii_prefix(const uint8_t *units, size_t count, uint8_t *ascii) {
    return fsk_ref_utf16le_ascii_prefix(units, count, ascii);
}
#endif
