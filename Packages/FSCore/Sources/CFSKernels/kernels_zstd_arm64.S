// The zstd sequence loop in arm64 assembly (RFC 8878 §3.1.1.3.2 and §3.1.1.4; roadmap 0013, docs/research/
// 2026-10-30-compression-kernels.md): decode every sequence of a block and execute it, as the C loop in zstd.c's
// `sequences` does, which stays as the reference (`fsk_ref_zstd_decompress_frame`) and the non-arm64 build.
//
// What it does differently from the C loop, for speed, never for result:
// - The bitstream is read through a 64-bit window holding at least 57 unread bits, refilled without a branch once per
//   sequence; the C loop loads at every read. A sequence of more than 57 bits takes a path that refills before each field.
// - Every field of a sequence is cut from the window at its own place, worked out from the three cells' widths alone, so no
//   field waits for the one before. A cell's first byte is its width (state bits + extra bits) and its second its state
//   bits, so a sequence's bits are one sum of the three cells, whose low byte is the total (at most 89: no carry). Shift
//   amounts only use their low 6 bits, so they come from whole cells and from cells shifted right by 8: what lies above
//   adds multiples of 256. Each field is masked to its width (-1 << width, cleared), which makes a width of 0 read 0.
// - Field widths of 0 cost no branch (the C loop's `count == 0` test is data-dependent).
// - A match fewer than 16 bytes back repeats its pattern 16 bytes at a time through TBL (the C loop copies those bytes one
//   by one).
// - Reading past the stream's start is not checked per read: the position only falls, so the end's "used up exactly" test
//   catches it, and until then every value read is bounded by its width, every table index by its table and every copy by
//   its checks.
//
// Apple arm64 ABI: x0 = the zstd_sequences block (layout in zstd.c, checked there by _Static_assert); x18 untouched;
// x19-x28 and x30 saved on the stack, x29 untouched; no calls.

#if defined(__aarch64__)

// Registers.
//   x1 ll table   x2 of table   x3 ml table   x4 stream   x5 unread bits in the window (57 to 64)   x6 window
//   x7 stream position - 57 (bits below the position unread)   x8 lit   x9 litEnd   x10 -1   x11 at   x12 end
//   x13 sequences left   w14 w15 w16 rep[0..2]   x17 ll state   x19 of state   x20 ml state   x21 x22 x23 ll, of, ml cells
//   x24 offset   x25 match   x26 literals   x0 x27 x28 x30 scratch
// Stack: x19-x28, x30 and the zstd_sequences pointer, then the output's base (at sp + 96).
// A cell (seq_cell): width (8 bits), state bits (8), baseline (16), base value (32).

// The window: the 8 bytes from max(0, (position - 57) / 8), x5 its bits up to the position. Near the stream's start that
// is its first 8 bytes: a branch, taken only there and so predicted, keeps the clamp off the chain from one sequence's
// bits to the next one's window.
.macro REFILL
    asr     x27, x7, #3
    tbz     x7, #63, 7f
    mov     x27, #0
7:  ldr     x6, [x4, x27]
    add     x5, x7, #57
    sub     x5, x5, x27, lsl #3
.endm

// \dst = the next \n bits (\n a register, 0 to 57, at most x5 in a valid stream), most significant first.
.macro READ dst, n
    sub     x5, x5, \n
    lsr     \dst, x6, x5
    lsl     x30, x10, \n
    bic     \dst, \dst, x30
    sub     x7, x7, \n
.endm

// The three values (offset x24, match x25, literals x26), x26 holding on entry the shift that puts the literals state's
// bits at the bottom of the window. Fields in the stream: offset, match, literals extra bits, then the three states.
.macro VALUES
    lsr     x0, x21, #8
    add     x0, x26, x0
    add     x28, x26, x21
    add     x30, x28, x23
    sub     x30, x30, x23, lsr #8
    lsr     x26, x6, x0
    lsr     x25, x6, x28
    lsr     x24, x6, x30
    sub     x0, x21, x21, lsr #8
    sub     x28, x23, x23, lsr #8
    sub     x30, x22, x22, lsr #8
    lsl     x0, x10, x0
    lsl     x28, x10, x28
    lsl     x30, x10, x30
    bic     x26, x26, x0
    bic     x25, x25, x28
    bic     x24, x24, x30
    add     x26, x26, x21, lsr #32
    add     x25, x25, x23, lsr #32
    add     x24, x24, x22, lsr #32
.endm

.text

// int32_t fsk_zstd_sequences(zstd_sequences *sequences)
.globl _fsk_zstd_sequences
.p2align 4
_fsk_zstd_sequences:
    stp     x19, x20, [sp, #-112]!
    stp     x21, x22, [sp, #16]
    stp     x23, x24, [sp, #32]
    stp     x25, x26, [sp, #48]
    stp     x27, x28, [sp, #64]
    stp     x30, x0, [sp, #80]
    ldp     x1, x2, [x0]
    ldp     x3, x4, [x0, #16]
    ldr     x5, [x0, #32]
    ldp     x8, x9, [x0, #40]
    ldp     x27, x11, [x0, #56]
    str     x27, [sp, #96]
    ldp     x12, x13, [x0, #72]
    ldp     w14, w15, [x0, #88]
    ldr     w16, [x0, #96]
    mov     x10, #-1
    // The stream ends with a 1 bit above its first bits: the position is that bit's.
    sub     x27, x5, #1
    ldrb    w28, [x4, x27]
    cbz     w28, Lzs_bad
    clz     w28, w28
    lsl     x7, x27, #3
    sub     x7, x7, x28
    sub     x7, x7, #26
    REFILL
    ldr     w27, [x0, #100]
    READ    x17, x27
    ldr     w27, [x0, #104]
    READ    x19, x27
    ldr     w27, [x0, #108]
    READ    x20, x27
    REFILL

Lzs_sequence:
    ldr     x21, [x1, x17, lsl #3]
    ldr     x22, [x2, x19, lsl #3]
    ldr     x23, [x3, x20, lsl #3]
    add     x27, x21, x23
    sub     x28, x5, x22
    add     x0, x27, x22
    sub     x28, x28, x27
    and     x30, x0, #0xFF
    cmp     x30, #57
    b.hi    Lzs_wide
    // x30: the sequence's bits; x28: the shift that puts the offset state's bits at the bottom of the window (the last
    // field, ending at the total). The match state's ends before those, the literals state's before that.
    sub     x7, x7, x30
    lsr     x24, x22, #8
    lsr     x25, x23, #8
    add     x26, x24, x25
    add     x30, x28, x24
    add     x26, x28, x26
    subs    x13, x13, #1
    b.eq    Lzs_last
    lsr     x19, x6, x28
    lsr     x20, x6, x30
    lsr     x17, x6, x26
    lsl     x24, x10, x24
    lsl     x25, x10, x25
    lsr     x28, x21, #8
    lsl     x28, x10, x28
    bic     x19, x19, x24
    bic     x20, x20, x25
    bic     x17, x17, x28
    ubfx    x24, x22, #16, #16
    ubfx    x25, x23, #16, #16
    ubfx    x28, x21, #16, #16
    add     x19, x19, x24
    add     x20, x20, x25
    add     x17, x17, x28
    VALUES
    REFILL

Lzs_execute:
    // Repeat offsets: an offset value above 3 is a new offset; 1 to 3 name a repeat (shifted by one without literals).
    cmp     x24, #3
    b.ls    Lzs_repeat
    mov     w16, w15
    mov     w15, w14
    sub     w14, w24, #3
Lzs_literals:
    // Room for the literals, the match and 16 bytes more (most sequences): every move may run 16 bytes past its end, and
    // only the literals and the offset are left to check. Otherwise each check on its own (Lzs_careful).
    sub     x27, x12, x11
    add     x28, x26, x25
    add     x28, x28, #16
    cmp     x28, x27
    b.hi    Lzs_careful
    sub     x27, x9, x8
    cmp     x26, x27
    b.hi    Lzs_bad
    ldr     q0, [x8]
    str     q0, [x11]
    cmp     x26, #16
    b.hi    Lzs_literals_long
    add     x8, x8, x26
    add     x11, x11, x26
    // The offset: 1 to the bytes produced (offset - 1 below them, unsigned, rules out 0 too).
    mov     w27, w14
    ldr     x28, [sp, #96]
    sub     x28, x11, x28
    sub     x30, x27, #1
    cmp     x30, x28
    b.hs    Lzs_bad
    sub     x30, x11, x27
    cmp     x27, #16
    b.lo    Lzs_match_near
    ldr     q0, [x30]
    str     q0, [x11]
    cmp     x25, #16
    b.hi    Lzs_match_long
    b       Lzs_next
Lzs_careful:
    sub     x27, x9, x8
    cmp     x26, x27
    b.hi    Lzs_bad
    sub     x27, x12, x11
    cmp     x26, x27
    b.hi    Lzs_bad
    sub     x27, x27, x26
    cmp     x27, #16
    b.lo    Lzs_literals_tail
    // 16-byte moves; the last may run past the literals, within the room checked (the literals buffer has 32 bytes of slack).
    ldr     q0, [x8]
    str     q0, [x11]
    cmp     x26, #16
    b.hi    Lzs_literals_long
Lzs_match:
    add     x8, x8, x26
    add     x11, x11, x26
    mov     w27, w14
    ldr     x28, [sp, #96]
    sub     x28, x11, x28
    sub     x30, x27, #1
    cmp     x30, x28
    b.hs    Lzs_bad
    sub     x28, x12, x11
    cmp     x25, x28
    b.hi    Lzs_bad
    sub     x28, x28, x25
    cmp     x28, #16
    b.lo    Lzs_match_tail
    sub     x30, x11, x27
    cmp     x27, #16
    b.lo    Lzs_match_near
    // 16 back or more: 16-byte moves front to back, each reading bytes already final.
    ldr     q0, [x30]
    str     q0, [x11]
    cmp     x25, #16
    b.hi    Lzs_match_long
Lzs_next:
    add     x11, x11, x25
    cbnz    x13, Lzs_sequence

    // The stream must be used up exactly (position 0): a read past its start leaves it below.
    cmn     x7, #57
    b.ne    Lzs_bad
    ldr     x0, [sp, #88]
    str     x8, [x0, #40]
    str     x11, [x0, #64]
    stp     w14, w15, [x0, #88]
    str     w16, [x0, #96]
    mov     w0, #0
    b       Lzs_return
Lzs_bad:
    mov     w0, #-1
Lzs_return:
    ldp     x21, x22, [sp, #16]
    ldp     x23, x24, [sp, #32]
    ldp     x25, x26, [sp, #48]
    ldp     x27, x28, [sp, #64]
    ldr     x30, [sp, #80]
    ldp     x19, x20, [sp], #112
    ret


// The last sequence reads no state bits: they go back to the position.
Lzs_last:
    ubfx    x30, x0, #8, #8
    add     x7, x7, x30
    VALUES
    b       Lzs_execute

// A sequence of more than 57 bits: a refill before each value (31 bits at most) and before the states (26 at most).
Lzs_wide:
    and     x27, x22, #0xFF
    ubfx    x28, x22, #8, #8
    sub     x27, x27, x28
    READ    x24, x27
    add     x24, x24, x22, lsr #32
    REFILL
    and     x27, x23, #0xFF
    ubfx    x28, x23, #8, #8
    sub     x27, x27, x28
    READ    x25, x27
    add     x25, x25, x23, lsr #32
    REFILL
    and     x27, x21, #0xFF
    ubfx    x28, x21, #8, #8
    sub     x27, x27, x28
    READ    x26, x27
    add     x26, x26, x21, lsr #32
    subs    x13, x13, #1
    b.eq    Lzs_execute
    REFILL
    ubfx    x27, x21, #8, #8
    READ    x17, x27
    ubfx    x28, x21, #16, #16
    add     x17, x17, x28
    ubfx    x27, x23, #8, #8
    READ    x20, x27
    ubfx    x28, x23, #16, #16
    add     x20, x20, x28
    ubfx    x27, x22, #8, #8
    READ    x19, x27
    ubfx    x28, x22, #16, #16
    add     x19, x19, x28
    REFILL
    b       Lzs_execute

Lzs_repeat:
    // index = offset value - 1, + 1 without literals: 0 keeps rep[0], 1 and 2 bring rep[1] or rep[2] to the front, 3 is
    // rep[0] - 1. That is 0 when rep[0] is 1, which is malformed: the match's offset check refuses it (the C loop refuses
    // it here; the verdict is the same).
    sub     x27, x24, #1
    cmp     x26, #0
    cinc    x27, x27, eq
    cbz     x27, Lzs_literals
    cmp     x27, #2
    b.lo    Lzs_repeat1
    b.eq    Lzs_repeat2
    sub     w28, w14, #1
    mov     w16, w15
    mov     w15, w14
    mov     w14, w28
    b       Lzs_literals
Lzs_repeat1:
    mov     w28, w15
    mov     w15, w14
    mov     w14, w28
    b       Lzs_literals
Lzs_repeat2:
    mov     w28, w16
    mov     w16, w15
    mov     w15, w14
    mov     w14, w28
    b       Lzs_literals

Lzs_literals_long:
    add     x27, x11, x26
    add     x28, x8, #16
    add     x0, x11, #16
1:  ldr     q0, [x28], #16
    str     q0, [x0], #16
    cmp     x0, x27
    b.lo    1b
    b       Lzs_match

Lzs_literals_tail:
    // Fewer than 16 bytes of room after them: byte by byte.
    cbz     x26, Lzs_match
    mov     x27, #0
1:  ldrb    w28, [x8, x27]
    strb    w28, [x11, x27]
    add     x27, x27, #1
    cmp     x27, x26
    b.lo    1b
    b       Lzs_match

Lzs_match_long:
    add     x27, x11, x25
    add     x28, x30, #16
    add     x0, x11, #16
1:  ldr     q0, [x28], #16
    str     q0, [x0], #16
    cmp     x0, x27
    b.lo    1b
    b       Lzs_next

Lzs_match_near:
    // 1 to 15 back: the pattern is the d bytes before the cursor. TBL spreads them over 16 bytes (index i mod d), stored
    // every 16 - 16 mod d bytes (a whole number of patterns), the last store within the 16 bytes of room checked. The load's
    // bytes at and past the cursor are not final, and not used.
    adrp    x28, zs_near_pattern@PAGE
    add     x28, x28, zs_near_pattern@PAGEOFF
    ldr     q1, [x28, x27, lsl #4]
    ldr     q0, [x30]
    tbl     v0.16b, {v0.16b}, v1.16b
    add     x28, x28, #256
    ldrb    w28, [x28, x27]
    add     x27, x11, x25
    mov     x0, x11
1:  str     q0, [x0]
    add     x0, x0, x28
    cmp     x0, x27
    b.lo    1b
    b       Lzs_next

Lzs_match_tail:
    // Fewer than 16 bytes of room after it: byte by byte, front to back (an overlapping match repeats its pattern).
    sub     x30, x11, x27
    mov     x28, #0
1:  ldrb    w0, [x30, x28]
    strb    w0, [x11, x28]
    add     x28, x28, #1
    cmp     x28, x25
    b.lo    1b
    b       Lzs_next

.section __TEXT,__const
.p2align 4
// For d = 0 to 15: 16 bytes of i mod d (d = 0 unused), then 16 bytes of strides 16 - 16 mod d.
zs_near_pattern:
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 0,1,0,1,0,1,0,1,0,1,0,1,0,1,0,1
    .byte 0,1,2,0,1,2,0,1,2,0,1,2,0,1,2,0
    .byte 0,1,2,3,0,1,2,3,0,1,2,3,0,1,2,3
    .byte 0,1,2,3,4,0,1,2,3,4,0,1,2,3,4,0
    .byte 0,1,2,3,4,5,0,1,2,3,4,5,0,1,2,3
    .byte 0,1,2,3,4,5,6,0,1,2,3,4,5,6,0,1
    .byte 0,1,2,3,4,5,6,7,0,1,2,3,4,5,6,7
    .byte 0,1,2,3,4,5,6,7,8,0,1,2,3,4,5,6
    .byte 0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5
    .byte 0,1,2,3,4,5,6,7,8,9,10,0,1,2,3,4
    .byte 0,1,2,3,4,5,6,7,8,9,10,11,0,1,2,3
    .byte 0,1,2,3,4,5,6,7,8,9,10,11,12,0,1,2
    .byte 0,1,2,3,4,5,6,7,8,9,10,11,12,13,0,1
    .byte 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,0
    .byte 16,16,16,15,16,15,12,14,16,9,10,11,12,13,14,15

#endif
