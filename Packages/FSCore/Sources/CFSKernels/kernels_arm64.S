// arm64 kernel for fskernels.h: the NTFS update sequence ("fixups"), format-specific, so it stays here while the generic
// kernels (CRC-32C, bit counts, UTF-16 narrowing) come from aemi (ADR-0012). Apple arm64 ABI: arguments in x0..x7, x18 is
// reserved and never touched, only caller-saved registers are used, so no frame is needed. kernels_portable.c holds the C
// version, the test reference and the non-arm64 build.

#if defined(__aarch64__)

.text

// int32_t fsk_ntfs_apply_fixups(uint8_t *record, size_t size, size_t stride)
//   x0 record, x1 size, x2 stride. Validates the whole header before writing anything.
.globl _fsk_ntfs_apply_fixups
.p2align 4
_fsk_ntfs_apply_fixups:
    cmp     x1, #8
    b.lo    Lfix_bad
    cmp     x2, #2
    b.lo    Lfix_bad
    ldrh    w3, [x0, #4]            // usa offset
    ldrh    w4, [x0, #6]            // usa count, including the sequence number itself
    cbz     w4, Lfix_bad
    tst     w3, #1
    b.ne    Lfix_bad
    udiv    x5, x1, x2              // strides in the record
    msub    x6, x5, x2, x1
    cbnz    x6, Lfix_bad            // size is a whole number of strides
    sub     x7, x4, #1
    cmp     x7, x5
    b.ne    Lfix_bad                // one entry per stride
    add     x8, x3, x4, lsl #1
    cmp     x8, x1
    b.hi    Lfix_bad                // the array lies inside the record
    add     x9, x0, x3
    ldrh    w10, [x9], #2           // update sequence number
    sub     x11, x2, #2
    add     x11, x0, x11            // last two bytes of the first stride
    cbz     x7, Lfix_ok
Lfix_loop:
    ldrh    w12, [x11]
    cmp     w12, w10
    b.ne    Lfix_torn
    ldrh    w13, [x9], #2
    strh    w13, [x11]
    add     x11, x11, x2
    subs    x7, x7, #1
    b.ne    Lfix_loop
Lfix_ok:
    mov     w0, #0
    ret
Lfix_bad:
    mov     w0, #-1
    ret
Lfix_torn:
    mov     w0, #-2
    ret

#endif
