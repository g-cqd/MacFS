// The best C a compiler gets from intrinsics, as the fair baseline for the kernels FSCore uses (aemi's since ADR-0012). Benchmark-only.
#ifndef FSK_BASELINE_H
#define FSK_BASELINE_H
#include <stddef.h>
#include <stdint.h>
uint32_t base_crc32c_serial(uint32_t crc, const uint8_t *bytes, size_t count);
uint32_t base_crc32c_threeway(uint32_t crc, const uint8_t *bytes, size_t count);
uint32_t base_crc32c_fold8(uint32_t crc, const uint8_t *bytes, size_t count);
uint64_t base_popcount(const uint8_t *bytes, size_t count);
size_t base_utf16le_ascii_prefix(const uint8_t *units, size_t count, uint8_t *ascii);
// MacFS's former assembly kernels (kernels_asm.S), kept for comparison with aemi's (ADR-0012).
uint32_t base_crc32c_asm(uint32_t crc, const uint8_t *bytes, size_t count);
uint64_t base_popcount_asm(const uint8_t *bytes, size_t count);
size_t base_utf16le_ascii_prefix_asm(const uint8_t *units, size_t count, uint8_t *ascii);
#endif
