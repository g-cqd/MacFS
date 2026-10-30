// fsk_abi_call (kernel_abi.h): a call with every callee-saved register of the Apple arm64 ABI set to a value of its own,
// and the mask of those the callee left changed. Tests only.

#if defined(__aarch64__)

// \reg = a value no kernel computes by chance: 0xA5A5 in the top half-word, \low in the bottom one.
.macro PATTERN reg, low
    movz    \reg, #\low
    movk    \reg, #0xA5A5, lsl #48
.endm

// Bit \bit of w0 when x\reg is not PATTERN \low.
.macro CHECK reg, low, bit
    PATTERN x9, \low
    cmp     \reg, x9
    cset    w10, ne
    orr     w0, w0, w10, lsl #\bit
.endm

// Bit \bit of w0 when d\reg is not PATTERN \low.
.macro CHECKD reg, low, bit
    fmov    x11, \reg
    CHECK   x11, \low, \bit
.endm

.text

// uint32_t fsk_abi_call(const void *function, const uint64_t *arguments, uint64_t *result)
.globl _fsk_abi_call
.p2align 2
_fsk_abi_call:
    stp     x29, x30, [sp, #-176]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]
    stp     x27, x28, [sp, #80]
    stp     d8, d9, [sp, #96]
    stp     d10, d11, [sp, #112]
    stp     d12, d13, [sp, #128]
    stp     d14, d15, [sp, #144]
    mov     x9, sp
    stp     x2, x9, [sp, #160]
    mov     x16, x0
    mov     x17, x1
    PATTERN x19, 19
    PATTERN x20, 20
    PATTERN x21, 21
    PATTERN x22, 22
    PATTERN x23, 23
    PATTERN x24, 24
    PATTERN x25, 25
    PATTERN x26, 26
    PATTERN x27, 27
    PATTERN x28, 28
    PATTERN x9, 108
    fmov    d8, x9
    PATTERN x9, 109
    fmov    d9, x9
    PATTERN x9, 110
    fmov    d10, x9
    PATTERN x9, 111
    fmov    d11, x9
    PATTERN x9, 112
    fmov    d12, x9
    PATTERN x9, 113
    fmov    d13, x9
    PATTERN x9, 114
    fmov    d14, x9
    PATTERN x9, 115
    fmov    d15, x9
    mov     x29, sp
    ldp     x0, x1, [x17]
    ldp     x2, x3, [x17, #16]
    ldp     x4, x5, [x17, #32]
    blr     x16
    ldp     x2, x12, [sp, #160]
    str     x0, [x2]
    mov     w0, #0
    CHECK   x19, 19, 0
    CHECK   x20, 20, 1
    CHECK   x21, 21, 2
    CHECK   x22, 22, 3
    CHECK   x23, 23, 4
    CHECK   x24, 24, 5
    CHECK   x25, 25, 6
    CHECK   x26, 26, 7
    CHECK   x27, 27, 8
    CHECK   x28, 28, 9
    cmp     x29, x12
    cset    w10, ne
    orr     w0, w0, w10, lsl #10
    mov     x9, sp
    cmp     x9, x12
    cset    w10, ne
    orr     w0, w0, w10, lsl #11
    CHECKD  d8, 108, 12
    CHECKD  d9, 109, 13
    CHECKD  d10, 110, 14
    CHECKD  d11, 111, 15
    CHECKD  d12, 112, 16
    CHECKD  d13, 113, 17
    CHECKD  d14, 114, 18
    CHECKD  d15, 115, 19
    ldp     d14, d15, [sp, #144]
    ldp     d12, d13, [sp, #128]
    ldp     d10, d11, [sp, #112]
    ldp     d8, d9, [sp, #96]
    ldp     x27, x28, [sp, #80]
    ldp     x25, x26, [sp, #64]
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #176
    ret

// A function that breaks the ABI on purpose, x25 and d9 changed, for fsk_abi_clobber_for_test.
.p2align 2
Labi_clobber:
    mov     x25, #0
    fmov    d9, xzr
    ret

// uint32_t fsk_abi_clobber_for_test(void)
.globl _fsk_abi_clobber_for_test
.p2align 2
_fsk_abi_clobber_for_test:
    stp     x29, x30, [sp, #-64]!
    mov     x29, sp
    adr     x0, Labi_clobber
    add     x1, sp, #16
    stp     xzr, xzr, [x1]
    stp     xzr, xzr, [x1, #16]
    stp     xzr, xzr, [x1, #32]
    add     x2, sp, #56
    bl      _fsk_abi_call
    ldp     x29, x30, [sp], #64
    ret

#endif
