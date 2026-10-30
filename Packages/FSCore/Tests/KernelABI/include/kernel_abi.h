// What the assembly kernels owe their callers beyond their results: the Apple arm64 ABI's callee-saved registers
// (x19-x28, the frame pointer x29, sp, and the low halves of v8-v15) as they were. Tests only (KernelABITests).
#ifndef KERNEL_ABI_H
#define KERNEL_ABI_H

#include <stdint.h>

/// Calls `function(arguments[0], ..., arguments[5])` with every callee-saved register set to a value of its own, stores
/// its x0 in `result`, and returns the registers it left changed: bit n for x(19 + n) (0 to 9), bit 10 for x29, bit 11 for
/// sp, bit (12 + n) for d(8 + n) (12 to 19). 0 when it keeps the ABI. 0xFFFFFFFF on a machine other than arm64.
uint32_t fsk_abi_call(const void *_Nonnull function, const uint64_t *_Nonnull arguments, uint64_t *_Nonnull result);

/// The zstd sequence kernel (kernels_zstd_arm64.S; its block is private to zstd.c) through `fsk_abi_call`, on a block
/// whose stream ends in a zero byte, which it refuses (`result` -1), or on one sequence it decodes (`result` 0, and
/// "abcabc" at `output`, 64 bytes or more).
uint32_t fsk_abi_zstd_sequences(int valid, uint8_t *_Nonnull output, int64_t *_Nonnull result);

/// fsk_abi_call on a function that changes x25 and d9 and nothing else: the mask that names them, which shows the check
/// sees a change.
uint32_t fsk_abi_clobber_for_test(void);

#endif
