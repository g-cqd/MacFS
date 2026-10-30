#include "baseline.h"
#include <arm_acle.h>
#include <arm_neon.h>
#include <string.h>

uint32_t base_crc32c_serial(uint32_t crc, const uint8_t *bytes, size_t count) {
    while (count >= 8) {
        uint64_t word;
        memcpy(&word, bytes, 8);
        crc = __crc32cd(crc, word);
        bytes += 8;
        count -= 8;
    }
    while (count--) crc = __crc32cb(crc, *bytes++);
    return crc;
}

// The same three-stream fold as the assembly, in intrinsics, so the comparison is about code generation.
static uint32_t shift(uint32_t crc, uint32_t constant) {
    poly64_t product = (poly64_t)vmull_p64((poly64_t)crc, (poly64_t)constant);
    uint64_t low;
    memcpy(&low, &product, 8);
    return __crc32cd(0, low);
}

uint32_t base_crc32c_threeway(uint32_t crc, const uint8_t *bytes, size_t count) {
    while (count >= 3072) {
        uint32_t b = 0, c = 0;
        for (size_t i = 0; i < 1024; i += 8) {
            uint64_t x, y, z;
            memcpy(&x, bytes + i, 8);
            memcpy(&y, bytes + 1024 + i, 8);
            memcpy(&z, bytes + 2048 + i, 8);
            crc = __crc32cd(crc, x);
            b = __crc32cd(b, y);
            c = __crc32cd(c, z);
        }
        crc = shift(crc, 0xa51b6135u) ^ shift(b, 0x170076fau) ^ c;
        bytes += 3072;
        count -= 3072;
    }
    return base_crc32c_serial(crc, bytes, count);
}

// The assembly's eight-lane PMULL fold, in intrinsics: the fair baseline for the kernel since roadmap 0011.
static inline uint64x2_t fold(uint64x2_t acc, uint64x2_t block, poly64_t k0, poly64_t k1) {
    poly128_t low = vmull_p64((poly64_t)vgetq_lane_u64(acc, 0), k0);
    poly128_t high = vmull_p64((poly64_t)vgetq_lane_u64(acc, 1), k1);
    return veorq_u64(veorq_u64(vreinterpretq_u64_p128(low), vreinterpretq_u64_p128(high)), block);
}

uint32_t base_crc32c_fold8(uint32_t crc, const uint8_t *bytes, size_t count) {
    if (count < 256) return base_crc32c_serial(crc, bytes, count);
    uint64x2_t acc[8];
    for (int j = 0; j < 8; j++) acc[j] = vld1q_u64((const uint64_t *)(const void *)(bytes + 16 * j));
    acc[0] = veorq_u64(acc[0], vsetq_lane_u64((uint64_t)crc, vdupq_n_u64(0), 0));
    bytes += 128;
    count -= 128;
    while (count >= 128) {
        for (int j = 0; j < 8; j++)
            acc[j] = fold(acc[j], vld1q_u64((const uint64_t *)(const void *)(bytes + 16 * j)), 0x6992cea2u, 0x0d3b6092u);
        bytes += 128;
        count -= 128;
    }
    uint64x2_t a = acc[0];
    for (int j = 1; j < 8; j++) a = fold(a, acc[j], 0xf20c0dfeu, 0x493c7d27u);
    uint32_t c = __crc32cd(0, vgetq_lane_u64(a, 0));
    c = __crc32cd(c, vgetq_lane_u64(a, 1));
    return base_crc32c_serial(c, bytes, count);
}

uint64_t base_popcount(const uint8_t *bytes, size_t count) {
    uint64_t total = 0;
    size_t i = 0;
    for (; i + 8 <= count; i += 8) {
        uint64_t word;
        memcpy(&word, bytes + i, 8);
        total += (uint64_t)__builtin_popcountll(word);
    }
    for (; i < count; i++) total += (uint64_t)__builtin_popcount(bytes[i]);
    return total;
}

size_t base_utf16le_ascii_prefix(const uint8_t *units, size_t count, uint8_t *ascii) {
    size_t i = 0;
    for (; i < count; i++) {
        uint16_t unit = (uint16_t)(units[2 * i] | (units[2 * i + 1] << 8));
        if (unit >= 0x80) break;
        ascii[i] = (uint8_t)unit;
    }
    return i;
}
