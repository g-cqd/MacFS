// arm64 kernels for fskernels.h. Apple arm64 ABI: arguments in x0..x7, x18 is reserved and never
// touched, only caller-saved registers are used (x0..x15, v0..v7), so no frame is needed.
//
// The CRC-32C kernel runs three independent CRC streams over three adjacent blocks of K bytes, so
// the CRC unit's latency is hidden, then folds them together with carry-less multiplication:
//
//   crc(c, A||B||C) = shift(crc(c, A), 2K) ^ shift(crc(0, B), K) ^ crc(0, C)
//   shift(v, n)     = crc32cx(0, pmull(v, x^(8n-33) mod P))
//
// The constants are x^(16K-33) and x^(8K-33) mod P, bit-reflected. They and the identity are
// derived and checked in docs/research/2026-10-30-neon-kernels.md; Tests/FSCoreTests compares
// every length from 0 to 9000 against a bitwise reference.

#if defined(__aarch64__)

.arch_extension crc
.arch_extension aes

.section __TEXT,__const
.p2align 3
Lfold1024:
    .long 0xa51b6135, 0x170076fa
Lfold256:
    .long 0xdd7e3b0c, 0xb9e02b86

.text

// uint32_t fsk_crc32c_update(uint32_t crc, const uint8_t *bytes, size_t count)
//   w0 crc, x1 cursor, x2 bytes remaining
.globl _fsk_crc32c_update
.p2align 4
_fsk_crc32c_update:
    cmp     x2, #3072
    b.lo    Lcrc_mid
    adrp    x3, Lfold1024@PAGE
    add     x3, x3, Lfold1024@PAGEOFF
    ldr     s6, [x3]
    ldr     s7, [x3, #4]
Lcrc_big:
    mov     w4, #0
    mov     w5, #0
    add     x6, x1, #1024
    add     x7, x1, #2048
    mov     x8, #64
Lcrc_big_loop:
    ldp     x9, x10, [x1], #16
    ldp     x11, x12, [x6], #16
    ldp     x13, x14, [x7], #16
    crc32cx w0, w0, x9
    crc32cx w4, w4, x11
    crc32cx w5, w5, x13
    crc32cx w0, w0, x10
    crc32cx w4, w4, x12
    crc32cx w5, w5, x14
    subs    x8, x8, #1
    b.ne    Lcrc_big_loop
    add     x1, x1, #2048
    fmov    s0, w0
    fmov    s1, w4
    pmull   v0.1q, v0.1d, v6.1d
    pmull   v1.1q, v1.1d, v7.1d
    fmov    x9, d0
    fmov    x10, d1
    crc32cx w9, wzr, x9
    crc32cx w10, wzr, x10
    eor     w0, w9, w10
    eor     w0, w0, w5
    sub     x2, x2, #3072
    cmp     x2, #3072
    b.hs    Lcrc_big
Lcrc_mid:
    cmp     x2, #768
    b.lo    Lcrc_tail8
    adrp    x3, Lfold256@PAGE
    add     x3, x3, Lfold256@PAGEOFF
    ldr     s6, [x3]
    ldr     s7, [x3, #4]
Lcrc_mid_block:
    mov     w4, #0
    mov     w5, #0
    add     x6, x1, #256
    add     x7, x1, #512
    mov     x8, #16
Lcrc_mid_loop:
    ldp     x9, x10, [x1], #16
    ldp     x11, x12, [x6], #16
    ldp     x13, x14, [x7], #16
    crc32cx w0, w0, x9
    crc32cx w4, w4, x11
    crc32cx w5, w5, x13
    crc32cx w0, w0, x10
    crc32cx w4, w4, x12
    crc32cx w5, w5, x14
    subs    x8, x8, #1
    b.ne    Lcrc_mid_loop
    add     x1, x1, #512
    fmov    s0, w0
    fmov    s1, w4
    pmull   v0.1q, v0.1d, v6.1d
    pmull   v1.1q, v1.1d, v7.1d
    fmov    x9, d0
    fmov    x10, d1
    crc32cx w9, wzr, x9
    crc32cx w10, wzr, x10
    eor     w0, w9, w10
    eor     w0, w0, w5
    sub     x2, x2, #768
    cmp     x2, #768
    b.hs    Lcrc_mid_block
Lcrc_tail8:
    cmp     x2, #8
    b.lo    Lcrc_tail4
Lcrc_tail8_loop:
    ldr     x9, [x1], #8
    crc32cx w0, w0, x9
    sub     x2, x2, #8
    cmp     x2, #8
    b.hs    Lcrc_tail8_loop
Lcrc_tail4:
    tbz     x2, #2, Lcrc_tail2
    ldr     w9, [x1], #4
    crc32cw w0, w0, w9
Lcrc_tail2:
    tbz     x2, #1, Lcrc_tail1
    ldrh    w9, [x1], #2
    crc32ch w0, w0, w9
Lcrc_tail1:
    tbz     x2, #0, Lcrc_done
    ldrb    w9, [x1]
    crc32cb w0, w0, w9
Lcrc_done:
    ret

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

// uint64_t fsk_popcount(const uint8_t *bytes, size_t count)
//   x0 cursor, x1 remaining, x2 total
.globl _fsk_popcount
.p2align 4
_fsk_popcount:
    mov     x2, #0
    cmp     x1, #64
    b.lo    Lpop16
Lpop64:
    ld1     {v0.16b, v1.16b, v2.16b, v3.16b}, [x0], #64
    cnt     v0.16b, v0.16b
    cnt     v1.16b, v1.16b
    cnt     v2.16b, v2.16b
    cnt     v3.16b, v3.16b
    add     v0.16b, v0.16b, v1.16b  // at most 16 per lane
    add     v2.16b, v2.16b, v3.16b
    add     v0.16b, v0.16b, v2.16b  // at most 32 per lane
    uaddlv  h4, v0.16b
    fmov    w3, s4
    add     x2, x2, x3
    sub     x1, x1, #64
    cmp     x1, #64
    b.hs    Lpop64
Lpop16:
    cmp     x1, #16
    b.lo    Lpop1
    ld1     {v0.16b}, [x0], #16
    cnt     v0.16b, v0.16b
    uaddlv  h4, v0.16b
    fmov    w3, s4
    add     x2, x2, x3
    sub     x1, x1, #16
    b       Lpop16
Lpop1:
    cbz     x1, Lpop_done
    ldrb    w3, [x0], #1
    fmov    s0, w3
    cnt     v0.8b, v0.8b
    umov    w3, v0.b[0]
    add     x2, x2, x3
    sub     x1, x1, #1
    b       Lpop1
Lpop_done:
    mov     x0, x2
    ret

// size_t fsk_utf16le_ascii_prefix(const uint8_t *units, size_t count, uint8_t *ascii)
//   x0 units, x1 count, x2 ascii, x3 copied
.globl _fsk_utf16le_ascii_prefix
.p2align 4
_fsk_utf16le_ascii_prefix:
    mov     x3, #0
Lu16_block:
    sub     x4, x1, x3
    cmp     x4, #8
    b.lo    Lu16_unit
    add     x6, x0, x3, lsl #1
    ldr     q0, [x6]
    umaxv   h1, v0.8h
    fmov    w5, s1
    cmp     w5, #0x7f
    b.hi    Lu16_unit               // a non-ASCII unit in this block: finish one by one
    xtn     v2.8b, v0.8h
    str     d2, [x2, x3]
    add     x3, x3, #8
    b       Lu16_block
Lu16_unit:
    cmp     x3, x1
    b.hs    Lu16_done
    ldrh    w5, [x0, x3, lsl #1]
    cmp     w5, #0x7f
    b.hi    Lu16_done
    strb    w5, [x2, x3]
    add     x3, x3, #1
    b       Lu16_unit
Lu16_done:
    mov     x0, x3
    ret

#endif
