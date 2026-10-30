// The portable NTFS fixups for targets without kernels_arm64.S (x86_64), and the reference the arm64 kernel is tested
// against: built on every target as fsk_ref_ntfs_apply_fixups.
#include "fskernels.h"

int32_t fsk_ref_ntfs_apply_fixups(uint8_t *record, size_t size, size_t stride);

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

#if !defined(__aarch64__)
int32_t fsk_ntfs_apply_fixups(uint8_t *record, size_t size, size_t stride) {
    return fsk_ref_ntfs_apply_fixups(record, size, stride);
}
#endif
