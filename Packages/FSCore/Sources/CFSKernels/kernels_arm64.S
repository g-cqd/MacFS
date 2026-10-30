// arm64 kernels for fskernels.h: the NTFS update sequence ("fixups") and LZNT1 decompression, format-specific, so it stays here while the generic
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

// int32_t fsk_lznt1_decompress(const uint8_t *source, size_t count, uint8_t *target, size_t capacity)
//   x0 input cursor, x1 input end, x2 target, x3 target end; x4 chunk start, x5 chunk limit (4 KiB on), x6 chunk input end,
//   x7 output cursor, w9 flags under a sentinel bit, and for the position's band x2 (where it ends), w10 the length mask and
//   w14 the offset shift. Same results as fsk_ref_lznt1_decompress, faster by the moves
//   the byte-wise reference cannot make (docs/research/2026-10-30-compression-kernels.md): a run of literals found with
//   rbit+clz and moved as one 8-byte word; the offset/length split kept in registers and recomputed (with clz) only when the
//   position enters a new band, so a phrase's length is one mask away from its token; a phrase of up to 16 bytes at
//   least 8 back as one 16-byte move (16 back or more) or two dependent 8-byte ones; longer ones as 8-byte words front to
//   back (each word reads only bytes already final); a phrase 1 back as a run of one byte. Moves may run past a run or a
//   phrase, never past the chunk's limit: bytes past the cursor are rewritten or zeroed when the chunk ends, and no phrase
//   reads at or past the cursor.
.globl _fsk_lznt1_decompress
.p2align 4
_fsk_lznt1_decompress:
    add     x1, x0, x1
    add     x3, x2, x3
    mov     x4, x2
Lz_chunk:
    sub     x8, x1, x0
    cmp     x8, #2
    b.lo    Lz_rest                 // fewer than two bytes: the unit ends
    cmp     x4, x3
    b.hs    Lz_done                 // the unit is full
    ldrh    w8, [x0]
    cbz     w8, Lz_rest             // a zero header ends the unit
    and     x6, x8, #0xFFF
    add     x6, x6, #3
    add     x6, x0, x6
    cmp     x6, x1
    b.hi    Lz_bad                  // the chunk overruns the input
    add     x5, x4, #4096
    cmp     x5, x3
    b.hi    Lz_bad                  // or the unit
    add     x0, x0, #2
    mov     x7, x4
    tbnz    w8, #15, Lz_compressed
    sub     x8, x6, x0
    cmp     x8, #4096
    b.ne    Lz_bad                  // a stored chunk is 4 KiB exactly
Lz_stored:
    ldp     q0, q1, [x0], #32
    ldp     q2, q3, [x0], #32
    stp     q0, q1, [x7], #32
    stp     q2, q3, [x7], #32
    cmp     x7, x5
    b.lo    Lz_stored
    b       Lz_next
Lz_compressed:
    add     x2, x4, #17             // the first band: positions up to 16
    mov     w10, #0xFFF             // length mask
    mov     w14, #12                // offset shift
Lz_tag:
    cmp     x0, x6
    b.hs    Lz_fill                 // the chunk's input is done
    ldrb    w9, [x0], #1            // flags: eight tokens, low bit first
    orr     w9, w9, #0x100          // and a sentinel above them
    // The fast group: with 16 bytes of input (eight tokens take at most that) and 144 of room (seven 16-byte phrases and
    // one 16-byte move) no token can overrun, so only a phrase's distance is checked.
    sub     x8, x6, x0
    cmp     x8, #16
    b.lo    Lz_group
    sub     x8, x5, x7
    cmp     x8, #144
    b.lo    Lz_group
Lf_token:
    tbnz    w9, #0, Lf_phrase
    ldrb    w8, [x0], #1            // a literal
    strb    w8, [x7], #1
    lsr     w9, w9, #1
    cmp     w9, #1
    b.ne    Lf_token
    b       Lz_tag
Lf_phrase:
    cmp     x7, x2
    b.hs    Lz_band                 // a new band: the checked path takes this token
    ldrh    w11, [x0], #2
    lsr     w16, w11, w14
    add     x16, x16, #1            // distance
    and     w17, w11, w10
    add     x17, x17, #3            // length
    cmp     x16, #16
    b.lo    Lz_checks               // fewer than 16 back,
    cmp     x17, #16
    b.hi    Lz_checks               // or longer than 16: the checked path copies it
    sub     x12, x7, x4
    cmp     x16, x12
    b.hi    Lz_bad                  // reaches before the chunk
    sub     x13, x7, x16
    ldr     q0, [x13]
    str     q0, [x7]
    add     x7, x7, x17
    lsr     w9, w9, #1
    cmp     w9, #1
    b.ne    Lf_token
    b       Lz_tag
Lz_group:
    // A run of literals: the zero bits below the next phrase or the sentinel. One 8-byte move covers any run when 8 bytes
    // of input and of room remain; bytes past the run are rewritten or zeroed later.
    rbit    w11, w9
    clz     w11, w11                // n, the run's length
    cbz     w11, Lz_phrase
    sub     x12, x6, x0             // input left in the chunk
    cmp     x11, x12
    csel    x13, x11, x12, ls       // k, the literals the input still holds
    sub     x15, x5, x7
    cmp     x13, x15
    b.hi    Lz_bad                  // a literal past the chunk's 4 KiB
    cmp     x12, #8
    b.lo    Lz_lit_bytes
    cmp     x15, #8
    b.lo    Lz_lit_bytes
    ldr     x8, [x0]
    str     x8, [x7]
    add     x0, x0, x13
    add     x7, x7, x13
    b       Lz_lit_done
Lz_lit_bytes:
    mov     x15, x13
Lz_lit_byte:
    cbz     x15, Lz_lit_done
    ldrb    w8, [x0], #1
    strb    w8, [x7], #1
    sub     x15, x15, #1
    b       Lz_lit_byte
Lz_lit_done:
    cmp     x13, x11
    b.lo    Lz_tag                  // the input ended inside the run: the chunk is done
    lsr     w9, w9, w11
    cmp     w9, #1
    b.eq    Lz_tag                  // only the sentinel is left
Lz_phrase:
    cmp     x0, x6
    b.hs    Lz_tag                  // the input ended before this token
    sub     x8, x6, x0
    cmp     x8, #2
    b.lo    Lz_bad                  // a phrase cut short
    cmp     x7, x2
    b.hs    Lz_band                 // a new band of positions: the split moves (at most 8 times a chunk)
Lz_decode:
    ldrh    w11, [x0], #2
    lsr     w16, w11, w14
    add     x16, x16, #1            // distance
    and     w17, w11, w10
    add     x17, x17, #3            // length
Lz_checks:
    sub     x12, x7, x4             // position in the chunk
    cmp     x16, x12
    b.hi    Lz_bad                  // reaches before the chunk (or nothing is behind it)
    sub     x8, x5, x7
    cmp     x17, x8
    b.hi    Lz_bad                  // runs past its 4 KiB
    sub     x13, x7, x16            // from
    add     x15, x7, x17            // the phrase's end
    cmp     x16, #8
    b.lo    Lz_near
    cmp     x17, #16
    b.hi    Lz_long
    cmp     x8, #16
    b.lo    Lz_bytes                // no room for 16 bytes
    cmp     x16, #16
    b.lo    Lz_two
    ldr     q0, [x13]               // 16 or more back: one 16-byte move
    str     q0, [x7]
    mov     x7, x15
    b       Lz_after
Lz_two:
    ldr     x8, [x13]               // 8 to 15 back: the second word reads what the first wrote
    str     x8, [x7]
    ldr     x8, [x13, #8]
    str     x8, [x7, #8]
    mov     x7, x15
    b       Lz_after
Lz_long:
    sub     x8, x5, x15
    cmp     x8, #8
    b.lo    Lz_bytes                // no room for a word's overrun
    b       Lz_words
Lz_near:
    sub     x8, x5, x15
    cmp     x8, #8
    b.lo    Lz_bytes
    cmp     x16, #1
    b.ne    Lz_bytes
    ldrb    w8, [x13]               // one back: a run of one byte
    mov     x12, #0x0101010101010101
    mul     x8, x8, x12
Lz_run:
    str     x8, [x7], #8
    cmp     x7, x15
    b.lo    Lz_run
    mov     x7, x15
    b       Lz_after
Lz_words:
    ldr     x8, [x13], #8
    str     x8, [x7], #8
    cmp     x7, x15
    b.lo    Lz_words
    mov     x7, x15
    b       Lz_after
Lz_bytes:
    ldrb    w8, [x13], #1
    strb    w8, [x7], #1
    cmp     x7, x15
    b.lo    Lz_bytes
Lz_after:
    lsr     w9, w9, #1
    cmp     w9, #1
    b.ne    Lz_group
    b       Lz_tag
Lz_band:
    // The split for this position: shift = log2(position - 1) - 3 (position is past 16 here, so at least 1); the band ends
    // where position - 1 reaches 16 << shift.
    sub     x12, x7, x4
    sub     x12, x12, #1
    clz     x12, x12
    mov     x11, #60
    sub     x11, x11, x12
    mov     w10, #0xFFF
    lsr     w10, w10, w11
    mov     w14, #12
    sub     w14, w14, w11
    mov     x12, #16
    lsl     x12, x12, x11
    add     x2, x4, x12
    add     x2, x2, #1
    b       Lz_decode
Lz_fill:
    sub     x8, x5, x7              // the chunk decoded short: zero to its limit
    cmp     x8, #16
    b.lo    Lz_fill_bytes
    stp     xzr, xzr, [x7], #16
    b       Lz_fill
Lz_fill_bytes:
    cmp     x7, x5
    b.hs    Lz_next
    strb    wzr, [x7], #1
    b       Lz_fill_bytes
Lz_next:
    mov     x0, x6
    mov     x4, x5
    b       Lz_chunk
Lz_rest:
    sub     x8, x3, x4              // past the last chunk: zero to the unit's end
    cmp     x8, #16
    b.lo    Lz_rest_bytes
    stp     xzr, xzr, [x4], #16
    b       Lz_rest
Lz_rest_bytes:
    cmp     x4, x3
    b.hs    Lz_done
    strb    wzr, [x4], #1
    b       Lz_rest_bytes
Lz_done:
    mov     w0, #0
    ret
Lz_bad:
    mov     w0, #-1
    ret

#endif
