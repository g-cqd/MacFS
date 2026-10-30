// MacFS's former arm64 kernels (ADR-0011), kept as the benchmark's baseline after ADR-0012 moved CRC-32C, bit counts and
// UTF-16 narrowing to aemi. Renamed base_*_asm; the CRC's three-stream tiers, which only inputs of 768 bytes or more reached
// and the scalar code never saw after the eight-lane fold took everything from 256, are gone. Dev-only (MACFS_DEV=1).

#if defined(__aarch64__)

.arch_extension crc
.arch_extension aes

.section __TEXT,__const
.p2align 4
Lfold_v128:
    .quad 0x6992cea2, 0x0d3b6092
Lfold_v16:
    .quad 0xf20c0dfe, 0x493c7d27

.text

// One 128-bit fold: acc = acc[0..7] * k[0] ^ acc[8..15] * k[1] ^ block (carry-less).
.macro FOLD acc, block, k
    pmull   v4.1q, \acc\().1d, \k\().1d
    pmull2  \acc\().1q, \acc\().2d, \k\().2d
    eor     \acc\().16b, \acc\().16b, \block\().16b
    eor     \acc\().16b, \acc\().16b, v4.16b
.endm

// uint32_t base_crc32c_asm(uint32_t crc, const uint8_t *bytes, size_t count)
//   w0 crc, x1 cursor, x2 bytes remaining
//
// From 256 bytes: eight 128-bit accumulators (v16..v23) fold 128 bytes per iteration with PMULL, merge by
// 16-byte folds, and reduce with two crc32cx; the remaining bytes (under 128) go to the scalar code below.
// Derivation and constants: docs/research/2026-10-30-neon-kernels.md. Only caller-saved registers.
.globl _base_crc32c_asm
.p2align 4
_base_crc32c_asm:
    cmp     x2, #256
    b.lo    Lcrc_scalar
    ld1     {v16.16b, v17.16b, v18.16b, v19.16b}, [x1], #64
    ld1     {v20.16b, v21.16b, v22.16b, v23.16b}, [x1], #64
    fmov    s2, w0
    eor     v16.16b, v16.16b, v2.16b
    sub     x2, x2, #128
    adrp    x3, Lfold_v128@PAGE
    add     x3, x3, Lfold_v128@PAGEOFF
    ldr     q0, [x3]
    ldr     q1, [x3, #16]
Lv_loop:
    cmp     x2, #128
    b.lo    Lv_merge
    ld1     {v24.16b, v25.16b, v26.16b, v27.16b}, [x1], #64
    ld1     {v28.16b, v29.16b, v30.16b, v31.16b}, [x1], #64
    FOLD    v16, v24, v0
    FOLD    v17, v25, v0
    FOLD    v18, v26, v0
    FOLD    v19, v27, v0
    FOLD    v20, v28, v0
    FOLD    v21, v29, v0
    FOLD    v22, v30, v0
    FOLD    v23, v31, v0
    sub     x2, x2, #128
    b       Lv_loop
Lv_merge:
    FOLD    v16, v17, v1
    FOLD    v16, v18, v1
    FOLD    v16, v19, v1
    FOLD    v16, v20, v1
    FOLD    v16, v21, v1
    FOLD    v16, v22, v1
    FOLD    v16, v23, v1
    fmov    x9, d16
    mov     x10, v16.d[1]
    crc32cx w0, wzr, x9
    crc32cx w0, w0, x10
Lcrc_scalar:
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


// uint64_t base_popcount_asm(const uint8_t *bytes, size_t count)
//   x0 cursor, x1 remaining, x2 total
.globl _base_popcount_asm
.p2align 4
_base_popcount_asm:
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

// size_t base_utf16le_ascii_prefix_asm(const uint8_t *units, size_t count, uint8_t *ascii)
//   x0 units, x1 count, x2 ascii, x3 copied
.globl _base_utf16le_ascii_prefix_asm
.p2align 4
_base_utf16le_ascii_prefix_asm:
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
