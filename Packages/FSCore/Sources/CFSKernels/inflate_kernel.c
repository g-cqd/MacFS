// Raw DEFLATE (RFC 1951), MacFS's own decoder for Btrfs zlib extents: the same results, bytes and verdicts as the system libz
// through fsk_oracle_inflate (InflateTests). libz decodes until it must write a byte it has no room for, so with the output
// full it still reads block headers, builds tables and decodes the next code, and refuses what is malformed there; this
// decoder stops at the same points (`LEAVE`): a write without room, or bits the input does not have.
//
// Tables: one 32-bit entry per index of the next 11 (literal/length) or 8 (distance) bits, a second level for longer codes.
// Entry: bits 0-7 the bits it consumes (its code and the extra bits after it), 8-11 its code's length, or for a pointer to a
// second level that level's index bits; 16-31 the literal, base value or second-level offset; bit 15 a literal, 12 to 14 a
// second level, the end of block, a code libz refuses. One shift consumes a length or a distance with its extra bits.
#include "fskernels.h"

#include <string.h>

enum { LIT_BITS = 11, DIST_BITS = 8, PRE_BITS = 7, LIT_ENOUGH = 2342, DIST_ENOUGH = 402 };
enum { KIND_PRE, KIND_LIT, KIND_DIST };
enum { NEXT = 1, LEAVE = 2, END = 3, BAD = -1 };  // a block's end, a stop, the stream's end, a malformed stream

#define E_LITERAL 0x8000u
#define E_SUB 0x1000u
#define E_END 0x2000u
#define E_BAD 0x4000u

static const uint16_t length_base[29] = {3,  4,  5,  6,  7,  8,  9,  10, 11,  13,  15,  17,  19,  23, 27,
                                         31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258};
static const uint8_t length_extra[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
static const uint16_t dist_base[30] = {1,   2,   3,   4,   5,   7,    9,    13,   17,   25,   33,   49,   65,    97,    129,
                                       193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577};
static const uint8_t dist_extra[30] = {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13};

typedef struct {
    const uint8_t *in, *end;
    uint64_t bits;   // unread bits from the bottom; above `count`, zeros or the input's next bits
    unsigned count;
    uint8_t *base, *out, *limit;
    int fixed;       // the fixed tables are in lit and dist
    uint32_t lit[LIT_ENOUGH], dist[DIST_ENOUGH];
} inflater;

static int pull(inflater *z) {
    if (z->in == z->end) return 0;
    z->bits |= (uint64_t)*z->in++ << z->count;
    z->count += 8;
    return 1;
}

static int need(inflater *z, unsigned n) {
    while (z->count < n)
        if (!pull(z)) return 0;
    return 1;
}

static void consume(inflater *z, unsigned n) {
    z->bits >>= n;
    z->count -= n;
}

static uint32_t mask(unsigned n) { return (1u << n) - 1; }

static uint32_t entry(uint32_t value, unsigned extra, unsigned length) { return value << 16 | length << 8 | (length + extra); }

static uint32_t entry_for(int kind, unsigned symbol, unsigned length) {
    if (kind == KIND_PRE) return entry(symbol, 0, length);
    if (kind == KIND_LIT) {
        if (symbol < 256) return E_LITERAL | entry(symbol, 0, length);
        if (symbol == 256) return E_END | entry(0, 0, length);
        if (symbol >= 286) return E_BAD | entry(0, 0, length);  // 286 and 287, in the fixed code only
        return entry(length_base[symbol - 257], length_extra[symbol - 257], length);
    }
    if (symbol >= 30) return E_BAD | entry(0, 0, length);  // 30 and 31, in the fixed code only
    return entry(dist_base[symbol], dist_extra[symbol], length);
}

// The table of the canonical code `lengths[0..<n]` (0: unused), as zlib's inftrees.c judges it: -1 when over-subscribed, or
// incomplete unless a lone 1-bit code of literal/lengths or distances. No code at all is accepted: every entry then a 1-bit
// code that is refused when used, or a code length of 0 for the precode (libz decodes it so).
static int build(uint32_t *table, const uint8_t *lengths, unsigned n, int kind, unsigned root) {
    unsigned count[16] = {0}, offsets[16], next[16], remain[16], max = 0;
    uint16_t sorted[288];
    for (unsigned s = 0; s < n; s++) count[lengths[s]]++;  // count[0]: the unused, not read
    for (unsigned l = 15; l >= 1 && max == 0; l--)
        if (count[l]) max = l;
    if (max == 0) {
        uint32_t fill = kind == KIND_PRE ? entry(0, 0, 1) : E_BAD | entry(0, 0, 1);
        for (unsigned i = 0; i < 1u << root; i++) table[i] = fill;
        return 0;
    }
    int left = 1;
    for (unsigned l = 1; l <= 15; l++) {
        left = (left << 1) - (int)count[l];
        if (left < 0) return -1;
    }
    if (left > 0) {
        if (kind == KIND_PRE || max != 1) return -1;
        for (unsigned i = 0; i < 1u << root; i++) table[i] = E_BAD | entry(0, 0, 1);
    }
    offsets[1] = 0;
    for (unsigned l = 1; l < 15; l++) offsets[l + 1] = offsets[l] + count[l];
    unsigned symbols = 0, code = 0;
    for (unsigned s = 0; s < n; s++)
        if (lengths[s]) sorted[offsets[lengths[s]]++] = (uint16_t)s, symbols++;
    for (unsigned l = 1; l <= 15; l++) {
        next[l] = code;
        code = (code + count[l]) << 1;
    }
    memcpy(remain, count, sizeof remain);
    unsigned used = 1u << root, prefix = ~0u, start = 0, bits = 0;
    for (unsigned i = 0; i < symbols; i++) {
        unsigned s = sorted[i], l = lengths[s];
        unsigned reversed = __builtin_bitreverse32(next[l]++) >> (32 - l);
        uint32_t e = entry_for(kind, s, l);
        if (l <= root) {
            for (unsigned j = reversed; j < 1u << root; j += 1u << l) table[j] = e;
        } else {
            if ((reversed & mask(root)) != prefix) {
                // A second level for the codes sharing these first bits: as many bits as the longest needs (inftrees.c).
                prefix = reversed & mask(root);
                start = used;
                bits = l - root;
                int room = 1 << bits;
                while (bits + root < max) {
                    room -= (int)remain[bits + root];
                    if (room <= 0) break;
                    bits++;
                    room <<= 1;
                }
                table[prefix] = start << 16 | bits << 8 | E_SUB | root;
                used += 1u << bits;
            }
            for (unsigned j = reversed >> root; j < 1u << bits; j += 1u << (l - root)) table[start + j] = e;
        }
        remain[l]--;
    }
    return 0;
}

// The entry of the next code once its whole length is among the bits read; 0 when the input ends first.
static int decode(inflater *z, const uint32_t *table, unsigned root, uint32_t *entry) {
    for (;;) {
        uint32_t e = table[z->bits & mask(root)];
        if (e & E_SUB) e = table[(e >> 16) + ((z->bits >> root) & mask((e >> 8) & 15))];
        if (((e >> 8) & 15) <= z->count) {
            *entry = e;
            return 1;
        }
        if (!pull(z)) return 0;
    }
}

static int stored(inflater *z) {
    consume(z, z->count & 7);
    if (!need(z, 32)) return LEAVE;
    size_t length = z->bits & 0xFFFF;
    if (length != (((z->bits >> 16) & 0xFFFF) ^ 0xFFFF)) return BAD;
    consume(z, 32);
    z->in -= z->count >> 3;  // the whole bytes still in the bit buffer go back to the input
    z->bits = 0;
    z->count = 0;
    while (length) {
        size_t n = length, available = (size_t)(z->end - z->in), room = (size_t)(z->limit - z->out);
        if (n > available) n = available;
        if (n > room) n = room;
        if (n == 0) return LEAVE;
        memcpy(z->out, z->in, n);
        z->out += n;
        z->in += n;
        length -= n;
    }
    return NEXT;
}

static int dynamic(inflater *z) {
    static const uint8_t order[19] = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};
    if (!need(z, 14)) return LEAVE;
    unsigned nlen = (z->bits & 31) + 257, ndist = ((z->bits >> 5) & 31) + 1, ncode = ((z->bits >> 10) & 15) + 4;
    consume(z, 14);
    if (nlen > 286 || ndist > 30) return BAD;
    uint8_t lengths[286 + 30] = {0};
    for (unsigned i = 0; i < ncode; i++) {
        if (!need(z, 3)) return LEAVE;
        lengths[order[i]] = z->bits & 7;
        consume(z, 3);
    }
    uint32_t pre[1 << PRE_BITS];
    if (build(pre, lengths, 19, KIND_PRE, PRE_BITS)) return BAD;  // then each length is written before it is read
    unsigned have = 0, total = nlen + ndist;
    while (have < total) {
        uint32_t e;
        if (!decode(z, pre, PRE_BITS, &e)) return LEAVE;
        unsigned symbol = e >> 16, n = (e >> 8) & 15;
        if (symbol < 16) {
            consume(z, n);
            lengths[have++] = (uint8_t)symbol;
            continue;
        }
        unsigned extra = symbol == 16 ? 2 : symbol == 17 ? 3 : 7;
        if (!need(z, n + extra)) return LEAVE;
        consume(z, n);
        unsigned length = 0, copies;
        if (symbol == 16) {
            if (have == 0) return BAD;
            length = lengths[have - 1];
            copies = 3 + (z->bits & 3);
        } else {
            copies = (symbol == 17 ? 3 : 11) + (z->bits & mask(extra));
        }
        consume(z, extra);
        if (have + copies > total) return BAD;
        while (copies--) lengths[have++] = (uint8_t)length;
    }
    if (lengths[256] == 0) return BAD;  // no end-of-block code
    if (build(z->lit, lengths, nlen, KIND_LIT, LIT_BITS)) return BAD;
    if (build(z->dist, lengths + nlen, ndist, KIND_DIST, DIST_BITS)) return BAD;
    z->fixed = 0;
    return NEXT;
}

static void fixed(inflater *z) {
    uint8_t lengths[288];
    memset(lengths, 8, 144);
    memset(lengths + 144, 9, 112);
    memset(lengths + 256, 7, 24);
    memset(lengths + 280, 8, 8);
    build(z->lit, lengths, 288, KIND_LIT, LIT_BITS);
    memset(lengths, 5, 32);
    build(z->dist, lengths, 32, KIND_DIST, DIST_BITS);
    z->fixed = 1;
}

static uint64_t load64(const uint8_t *p) {
    uint64_t v;
    memcpy(&v, p, 8);
    return v;
}

#define REFILL()                         \
    do {                                 \
        bits |= load64(in) << (count & 63); \
        in += (~count & 63) >> 3;           \
        count |= 56;                        \
    } while (0)

// A match of `stop - out` bytes from `distance` back, in 16-, 8- or 1-byte moves; may write 15 bytes past `stop`.
static inline void copy_match(uint8_t *out, const uint8_t *from, uint8_t *stop, size_t distance) {
    if (distance >= 16) {
        do {
            memcpy(out, from, 16);
            out += 16;
            from += 16;
        } while (out < stop);
    } else if (distance >= 8) {
        do {
            memcpy(out, from, 8);
            out += 8;
            from += 8;
        } while (out < stop);
    } else if (distance == 1) {
        uint64_t run = from[0] * 0x0101010101010101ULL;
        do {
            memcpy(out, &run, 8);
            out += 8;
        } while (out < stop);
    } else {
        do *out++ = *from++;
        while (out < stop);
    }
}

static uint64_t extra_bits(uint64_t saved, uint32_t e) {
    return (saved & (((uint64_t)1 << (e & 0xFF)) - 1)) >> ((e >> 8) & 15);
}

// The symbols of a block. While 8 bytes of input and 274 of room remain (a match of 258 and a 16-byte move past it), a
// refill before each symbol needs no test: a symbol takes 48 bits at most (a length and a distance with their extra bits).
// Each entry is read before the refill and the copy before it, which then overlap the chain of table reads. Then one symbol
// at a time, each read checked, so that the decoder stops where libz stops.
static int codes(inflater *z) {
    const uint32_t *lit = z->lit, *dist = z->dist;
    uint8_t *const base = z->base, *const limit = z->limit;
    const uint8_t *const end = z->end;
    for (;;) {
        uint64_t bits = z->bits;
        unsigned count = z->count;
        const uint8_t *in = z->in;
        uint8_t *out = z->out;
        int verdict = 0;
        if (end - in >= 8) {
            REFILL();
            uint32_t e = lit[bits & mask(LIT_BITS)];
            for (;;) {
                // e is the entry of the bits' next code, or the pointer to its second level. It was read before this
                // refill, from bits that were all input: a refill makes all 64 real (count says 56 to 63), and a symbol
                // takes 48 at most; the refill adds the same bits again above `count`.
                if (end - in < 8 || limit - out < 274) break;
                REFILL();
            dispatch:;
                uint64_t saved = bits;
                if (e & E_LITERAL) {
                    bits >>= e & 0xFF;
                    count -= e;  // only its low byte is read: the bits' count, 0 to 63
                    *out++ = (uint8_t)(e >> 16);
                    e = lit[bits & mask(LIT_BITS)];
                    continue;
                }
                if (e & (E_SUB | E_END | E_BAD)) {  // one test for what is rare
                    if (e & E_SUB) {
                        e = lit[(e >> 16) + ((bits >> LIT_BITS) & mask((e >> 8) & 15))];
                        goto dispatch;
                    }
                    bits >>= e & 0xFF;
                    count -= e;
                    verdict = e & E_END ? NEXT : BAD;
                    break;
                }
                bits >>= e & 0xFF;
                count -= e;
                size_t length = (e >> 16) + extra_bits(saved, e);
                e = dist[bits & mask(DIST_BITS)];
                if (e & (E_SUB | E_BAD)) {
                    if (e & E_SUB) e = dist[(e >> 16) + ((bits >> DIST_BITS) & mask((e >> 8) & 15))];
                    if (e & E_BAD) {
                        verdict = BAD;
                        break;
                    }
                }
                saved = bits;
                bits >>= e & 0xFF;
                count -= e;
                size_t distance = (e >> 16) + extra_bits(saved, e);
                if (distance > (size_t)(out - base)) {
                    verdict = BAD;
                    break;
                }
                e = lit[bits & mask(LIT_BITS)];  // before the copy, which overlaps it
                copy_match(out, out - distance, out + length, distance);
                out += length;
            }
        }
        z->bits = bits;
        z->count = count & 0xFF;
        z->in = in;
        z->out = out;
        if (verdict) return verdict;

        // One symbol, every read checked.
        uint32_t e;
        if (!decode(z, lit, LIT_BITS, &e)) return LEAVE;
        unsigned n = (e >> 8) & 15, x = (e & 0xFF) - n;
        consume(z, n);
        if (e & E_LITERAL) {
            if (z->out == z->limit) return LEAVE;
            *z->out++ = (uint8_t)(e >> 16);
            continue;
        }
        if (e & E_END) return NEXT;
        if (e & E_BAD) return BAD;
        if (!need(z, x)) return LEAVE;
        size_t length = (e >> 16) + (z->bits & mask(x));
        consume(z, x);
        if (!decode(z, dist, DIST_BITS, &e)) return LEAVE;
        n = (e >> 8) & 15, x = (e & 0xFF) - n;
        consume(z, n);
        if (e & E_BAD) return BAD;
        if (!need(z, x)) return LEAVE;
        size_t distance = (e >> 16) + (z->bits & mask(x));
        consume(z, x);
        if (z->out == z->limit) return LEAVE;
        if (distance > (size_t)(z->out - z->base)) return BAD;
        size_t room = (size_t)(z->limit - z->out);
        if (room > length) room = length;
        const uint8_t *from = z->out - distance;
        for (size_t i = 0; i < room; i++) z->out[i] = from[i];
        z->out += room;
        if (room < length) return LEAVE;
    }
}

static int blocks(inflater *z) {
    for (;;) {
        if (!need(z, 3)) return LEAVE;
        unsigned last = z->bits & 1, type = (z->bits >> 1) & 3;
        consume(z, 3);
        int verdict;
        if (type == 0) {
            verdict = stored(z);
        } else if (type == 1) {
            if (!z->fixed) fixed(z);
            verdict = codes(z);
        } else if (type == 2) {
            verdict = dynamic(z);
            if (verdict == NEXT) verdict = codes(z);
        } else {
            return BAD;
        }
        if (verdict != NEXT) return verdict;
        if (last) return END;
    }
}

int32_t fsk_inflate(const uint8_t *source, size_t count, uint8_t *target, size_t capacity, size_t *produced) {
    inflater z;
    z.in = source;
    z.end = source + count;
    z.bits = 0;
    z.count = 0;
    z.base = z.out = target;
    z.limit = target + capacity;
    z.fixed = 0;
    int verdict = blocks(&z);
    *produced = (size_t)(z.out - target);
    if (verdict == BAD) return -1;
    if (verdict == END || z.out == z.limit) return 0;
    return -2;  // the input ended first
}
