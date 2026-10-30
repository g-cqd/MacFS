// The zstd sequence kernel's calls for KernelABITests (kernel_abi.h). Tests only.
#include "kernel_abi.h"

#include <string.h>

#if defined(__aarch64__)

// zstd.c's zstd_sequences and seq_cell, which kernels_zstd_arm64.S reads at these offsets (zstd.c asserts them too).
typedef struct {
    const uint64_t *ll, *of, *ml;
    const uint8_t *stream;
    size_t streamSize;
    const uint8_t *lit, *litEnd;
    uint8_t *base, *at, *end;
    size_t count;
    uint32_t rep[3];
    uint32_t llLog, ofLog, mlLog;
} sequences_block;
_Static_assert(__builtin_offsetof(sequences_block, streamSize) == 32 && __builtin_offsetof(sequences_block, base) == 56 &&
                   __builtin_offsetof(sequences_block, count) == 80 && __builtin_offsetof(sequences_block, rep) == 88 &&
                   __builtin_offsetof(sequences_block, llLog) == 100,
               "zstd.c's zstd_sequences");

int32_t fsk_zstd_sequences(sequences_block *block);

// A cell: width (state bits + extra bits), state bits, baseline, base value.
static uint64_t cell(uint64_t width, uint64_t value) { return width | value << 32; }

uint32_t fsk_abi_zstd_sequences(int valid, uint8_t *output, int64_t *result) {
    // One sequence of 3 literals, offset value 6 (3 back) and a match of 3, each with extra bits (20, 18, 18: 56, all
    // zero) and tables of one cell (no state bits): the 8-byte stream's top bit is bit 56. A zero last byte has none.
    uint64_t tables[3] = {cell(20, 3), cell(18, 6), cell(18, 3)};
    const uint8_t stream[8] = {0, 0, 0, 0, 0, 0, 0, valid ? 1 : 0}, literals[3] = {'a', 'b', 'c'};
    sequences_block block = {&tables[0], &tables[1], &tables[2], stream, 8, literals, literals + 3, output, output,
                             output + 64, 1, {1, 4, 8}, 0, 0, 0};
    const uint64_t arguments[6] = {(uint64_t)&block, 0, 0, 0, 0, 0};
    uint64_t x0 = 0;
    uint32_t changed = fsk_abi_call((const void *)fsk_zstd_sequences, arguments, &x0);
    *result = (int32_t)x0;
    return changed;
}

#else

uint32_t fsk_abi_call(const void *function, const uint64_t *arguments, uint64_t *result) {
    (void)function, (void)arguments;
    *result = 0;
    return 0xFFFFFFFF;
}

uint32_t fsk_abi_zstd_sequences(int valid, uint8_t *output, int64_t *result) {
    (void)valid, (void)output;
    *result = 0;
    return 0xFFFFFFFF;
}

uint32_t fsk_abi_clobber_for_test(void) { return 0xFFFFFFFF; }

#endif
