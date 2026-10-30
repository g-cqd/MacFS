// Hand-built raw DEFLATE streams (codec_oracle.h): each holds a rule of RFC 1951 and of zlib's inflate that libz's own
// encoder never writes, so that a decoder held to libz meets it. Tests only.
#include "codec_oracle.h"

#include <string.h>
#include <zlib.h>

typedef struct {
    uint8_t *data;
    size_t capacity, size;
    uint64_t bits;
    unsigned count;
} writer;

// `n` bits of `value`, the lowest first (RFC 1951 3.1.1).
static void put(writer *w, uint32_t value, unsigned n) {
    w->bits |= (uint64_t)(n < 32 ? value & ((1u << n) - 1) : value) << w->count;
    w->count += n;
    while (w->count >= 8) {
        if (w->size < w->capacity) w->data[w->size] = (uint8_t)w->bits;
        w->size++;
        w->bits >>= 8;
        w->count -= 8;
    }
}

static size_t finish(writer *w) {
    if (w->count) put(w, 0, 8 - w->count);
    return w->size <= w->capacity ? w->size : 0;
}

static uint32_t reversed(uint32_t code, unsigned length) {
    uint32_t r = 0;
    for (unsigned i = 0; i < length; i++) r |= ((code >> i) & 1) << (length - 1 - i);
    return r;
}

typedef struct {
    uint8_t lit[288], dist[32];  // code lengths, 0 for unused
    uint32_t litc[288], distc[32];
} code;

static void canonical(const uint8_t *lengths, unsigned n, uint32_t *codes) {
    unsigned count[16] = {0}, next[16];
    for (unsigned s = 0; s < n; s++)
        if (lengths[s]) count[lengths[s]]++;
    unsigned c = 0;
    for (unsigned l = 1; l <= 15; l++) {
        next[l] = c;
        c = (c + count[l]) << 1;
    }
    for (unsigned s = 0; s < n; s++) codes[s] = lengths[s] ? next[lengths[s]]++ : 0;
}

static void put_lit(writer *w, const code *c, unsigned symbol) { put(w, reversed(c->litc[symbol], c->lit[symbol]), c->lit[symbol]); }
static void put_dist(writer *w, const code *c, unsigned symbol) {
    put(w, reversed(c->distc[symbol], c->dist[symbol]), c->dist[symbol]);
}

static const uint16_t length_base[29] = {3,  4,  5,  6,  7,  8,  9,  10, 11,  13,  15,  17,  19,  23, 27,
                                         31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258};
static const uint8_t length_extra[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
static const uint16_t dist_base[30] = {1,   2,   3,   4,   5,   7,    9,    13,   17,   25,   33,   49,   65,    97,    129,
                                       193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577};
static const uint8_t dist_extra[30] = {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13};

// A match by its symbols and extra bits; symbols past the alphabet (286, 287, 30, 31) without extra bits.
static void match_symbols(writer *w, const code *c, unsigned lsym, unsigned lextra, unsigned dsym, unsigned dextra) {
    put_lit(w, c, lsym);
    if (lsym < 286) put(w, lextra, length_extra[lsym - 257]);
    put_dist(w, c, dsym);
    if (dsym < 30) put(w, dextra, dist_extra[dsym]);
}

static void match(writer *w, const code *c, unsigned length, unsigned distance) {
    unsigned l = 28, d = 29;
    while (length_base[l] > length) l--;
    while (dist_base[d] > distance) d--;
    match_symbols(w, c, 257 + l, length - length_base[l], d, distance - dist_base[d]);
}

static void fixed_code(code *c) {
    memset(c, 0, sizeof *c);
    memset(c->lit, 8, 144);
    memset(c->lit + 144, 9, 112);
    memset(c->lit + 256, 7, 24);
    memset(c->lit + 280, 8, 8);
    memset(c->dist, 5, 32);
    canonical(c->lit, 288, c->litc);
    canonical(c->dist, 32, c->distc);
}

static void block(writer *w, unsigned last, unsigned type) {
    put(w, last, 1);
    put(w, type, 2);
}

// A dynamic block's header for `c`'s lengths, through a precode of 4-bit codes for the lengths 0 to 15 (symbol k: code k).
static void dynamic_header(writer *w, unsigned last, code *c, unsigned nlen, unsigned ndist) {
    static const uint8_t order[19] = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};
    block(w, last, 2);
    put(w, nlen - 257, 5);
    put(w, ndist - 1, 5);
    put(w, 19 - 4, 4);
    for (unsigned i = 0; i < 19; i++) put(w, order[i] < 16 ? 4 : 0, 3);
    for (unsigned s = 0; s < nlen; s++) put(w, reversed(c->lit[s], 4), 4);
    for (unsigned s = 0; s < ndist; s++) put(w, reversed(c->dist[s], 4), 4);
    canonical(c->lit, 288, c->litc);
    canonical(c->dist, 32, c->distc);
}

static uint64_t next(uint64_t *state) {
    uint64_t z = (*state += 0x9E3779B97F4A7C15ULL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}

// Words, deterministic: what the flushed streams compress.
static size_t words(uint8_t *text, size_t n) {
    static const char *const list[] = {"the ", "of ", "and ", "block ", "tree ", "extent ", "inode ", "\n"};
    uint64_t state = 1951;
    size_t at = 0;
    while (at < n) {
        const char *word = list[next(&state) % 8];
        for (size_t i = 0; word[i] && at < n; i++) text[at++] = (uint8_t)word[i];
    }
    return n;
}

// libz's deflate of the words with a flush every `every` bytes (Z_SYNC_FLUSH and Z_FULL_FLUSH end with an empty stored
// block, Z_PARTIAL_FLUSH with an empty fixed block, Z_BLOCK at a block's end): blocks that start mid-byte after a
// compressed one.
static size_t flushed(writer *w, int level, int flush, size_t every, size_t *size) {
    static uint8_t text[30000];
    size_t n = words(text, sizeof text);
    *size = n;
    z_stream s = {0};
    if (deflateInit2(&s, level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) != Z_OK) return 0;
    s.next_out = w->data;
    s.avail_out = (uInt)(w->capacity < UINT32_MAX ? w->capacity : UINT32_MAX);
    for (size_t at = 0; at < n; at += every) {
        size_t k = n - at < every ? n - at : every;
        s.next_in = text + at;
        s.avail_in = (uInt)k;
        int f = at + k == n ? Z_FINISH : flush, r = deflate(&s, f);
        if (f == Z_FINISH ? r != Z_STREAM_END : r != Z_OK || s.avail_out == 0) {
            deflateEnd(&s);
            return 0;
        }
    }
    size_t length = (size_t)(s.next_out - w->data);
    deflateEnd(&s);
    return length;
}

// A random complete code with `leaves` of the first `symbols` symbols, at most 15 bits, often deep: a tree grown by
// splitting leaves, the last split one half of the time. `forced` symbols are among the leaves.
static void random_lengths(uint64_t *state, uint8_t *lengths, unsigned symbols, unsigned leaves, const unsigned *forced,
                           unsigned nforced) {
    uint8_t depth[288] = {0};
    unsigned have = 1, last = 0;
    while (have < leaves) {
        unsigned i = next(state) % 2 ? last : (unsigned)(next(state) % have);
        while (depth[i] >= 15) i = (unsigned)(next(state) % have);
        depth[i]++;
        depth[have] = depth[i];
        last = next(state) % 2 ? i : have;
        have++;
    }
    unsigned order[288];
    for (unsigned s = 0; s < symbols; s++) order[s] = s;
    for (unsigned s = symbols - 1; s > 0; s--) {
        unsigned j = (unsigned)(next(state) % (s + 1)), t = order[s];
        order[s] = order[j];
        order[j] = t;
    }
    for (unsigned f = 0; f < nforced; f++)
        for (unsigned s = 0; s < symbols; s++)
            if (order[s] == forced[f]) {
                order[s] = order[f];
                order[f] = forced[f];
            }
    memset(lengths, 0, symbols);
    for (unsigned i = 0; i < leaves; i++) lengths[order[i]] = depth[i];
}

// A dynamic block of a random deep code and random symbols: literals, lengths with every extra value, distances back
// into what was written.
static size_t random_block(writer *w, uint64_t seed, size_t *size) {
    uint64_t state = seed;
    code c = {0};
    unsigned lit_forced[] = {97, 256}, dist_forced[] = {0};
    random_lengths(&state, c.lit, 286, 2 + (unsigned)(next(&state) % 285), lit_forced, 2);
    random_lengths(&state, c.dist, 30, 2 + (unsigned)(next(&state) % 29), dist_forced, 1);
    dynamic_header(w, 1, &c, 286, 30);
    unsigned lits[286], nlits = 0, dists[30], ndists = 0;
    for (unsigned s = 0; s < 286; s++)
        if (c.lit[s] && s != 256) lits[nlits++] = s;
    for (unsigned s = 0; s < 30; s++)
        if (c.dist[s]) dists[ndists++] = s;
    size_t out = 0;
    for (unsigned step = 0; step < 1500; step++) {
        unsigned s = lits[next(&state) % nlits];
        if (s < 256) {
            put_lit(w, &c, s);
            out++;
            continue;
        }
        unsigned d = dists[next(&state) % ndists];
        uint32_t dextra = (uint32_t)(next(&state) & ((1u << dist_extra[d]) - 1));
        if (dist_base[d] + dextra > out) {
            put_lit(w, &c, 97);
            out++;
            continue;
        }
        uint32_t lextra = (uint32_t)(next(&state) & ((1u << length_extra[s - 257]) - 1));
        match_symbols(w, &c, s, lextra, d, dextra);
        out += length_base[s - 257] + lextra;  // 284 with 31: 258, which libz takes
    }
    put_lit(w, &c, 256);
    *size = out;
    return finish(w);
}

enum { FLUSHED = 5, RANDOM = 20, FIRST_RANDOM = 31 };

unsigned fsk_oracle_vector_count(void) { return FIRST_RANDOM + RANDOM; }

static void pad(writer *w) {  // input left after the symbols, as a fast path wants
    for (unsigned i = 0; i < 16; i++) put(w, 0, 8);
}

size_t fsk_oracle_vector(unsigned which, uint8_t *target, size_t capacity, const char **name, size_t *size) {
    writer w = {target, capacity, 0, 0, 0};
    code c = {0}, f;
    fixed_code(&f);
    *size = 0;
    if (which < FLUSHED) {
        static const int levels[] = {6, 1, 9, 6, 0}, flushes[] = {Z_SYNC_FLUSH, Z_FULL_FLUSH, Z_PARTIAL_FLUSH, Z_BLOCK, Z_SYNC_FLUSH};
        static const size_t every[] = {997, 1500, 700, 1100, 3000};
        static const char *const names[] = {"sync flushes", "full flushes", "partial flushes", "Z_BLOCK flushes",
                                            "stored blocks with sync flushes"};
        *name = names[which];
        return flushed(&w, levels[which], flushes[which], every[which], size);
    }
    if (which >= FIRST_RANDOM) {
        *name = "a random deep code";
        return random_block(&w, 7000 + which, size);
    }
    switch (which) {
    case 5:
    case 6:
    case 7: {
        *name = which == 5 ? "no distance code, a length after 400 literals"
              : which == 6 ? "no distance code, a length after 3 literals"
                           : "no distance code, literals only";
        c.lit[97] = 1, c.lit[256] = 2, c.lit[257] = 2;
        dynamic_header(&w, 1, &c, 258, 1);
        unsigned n = which == 5 ? 400 : 3;
        for (unsigned i = 0; i < n; i++) put_lit(&w, &c, 97);
        if (which != 7) put_lit(&w, &c, 257), put(&w, 0, 8);
        put_lit(&w, &c, 256);
        *size = n;
        if (which == 5) pad(&w);
        break;
    }
    case 8:
    case 9:
        *name = which == 8 ? "a lone 1-bit literal/length code, its unused code read" : "a lone 1-bit literal/length code";
        c.lit[256] = 1;
        dynamic_header(&w, 1, &c, 257, 1);
        put(&w, which == 8, 1);
        break;
    case 10:
    case 11:
    case 12: {
        *name = which == 10 ? "a lone 1-bit distance code, its unused code read"
              : which == 11 ? "a lone 1-bit distance code"
                            : "a lone 1-bit distance code, its unused code read after 400 literals";
        c.lit[97] = 1, c.lit[256] = 2, c.lit[257] = 2, c.dist[0] = 1;
        dynamic_header(&w, 1, &c, 258, 1);
        unsigned n = which == 12 ? 400 : 1;
        for (unsigned i = 0; i < n; i++) put_lit(&w, &c, 97);
        put_lit(&w, &c, 257);
        put(&w, which != 11, 1);
        put_lit(&w, &c, 256);
        *size = n + 3;
        if (which == 12) pad(&w);
        break;
    }
    case 13:
        *name = "a literal/length code one 15-bit code short";
        for (unsigned i = 0; i < 13; i++) c.lit[97 + i] = (uint8_t)(i + 1);
        c.lit[285] = 14, c.lit[256] = 15, c.dist[0] = 1, c.dist[1] = 1;
        dynamic_header(&w, 1, &c, 286, 2);
        put(&w, 0, 32);
        break;
    case 14:
        *name = "a distance code one 15-bit code short";
        c.lit[97] = 1, c.lit[256] = 2, c.lit[257] = 2;
        for (unsigned i = 0; i < 14; i++) c.dist[i] = (uint8_t)(i + 1);
        c.dist[29] = 15;
        dynamic_header(&w, 1, &c, 258, 30);
        put(&w, 0, 32);
        break;
    case 15:
    case 16:
    case 17:
        *name = which == 15 ? "31 distance codes" : which == 16 ? "287 literal/length codes" : "288 literal/length codes";
        block(&w, 1, 2);
        put(&w, which == 15 ? 0 : which == 16 ? 30 : 31, 5);
        put(&w, which == 15 ? 30 : 0, 5);
        put(&w, 15, 4);
        put(&w, 0x12345678, 32), put(&w, 0x9ABCDEF0, 32);
        break;
    case 18: {
        *name = "all 316 code lengths, length 258 and distance 24577";
        memset(c.lit, 8, 226), memset(c.lit + 226, 9, 60);
        c.dist[0] = 4, c.dist[1] = 4;
        memset(c.dist + 2, 5, 28);
        dynamic_header(&w, 1, &c, 286, 30);
        put_lit(&w, &c, 97);
        for (unsigned i = 0; i < 96; i++) match(&w, &c, 258, 1);
        match(&w, &c, 258, 24577);
        match(&w, &c, 3, 24577 + 8191 - 10000);
        put_lit(&w, &c, 256);
        *size = 1 + 97 * 258 + 3;
        break;
    }
    case 19:
        *name = "an all-zero precode, then the zero code lengths it reads";
        block(&w, 1, 2);
        put(&w, 0, 5), put(&w, 0, 5), put(&w, 0, 4), put(&w, 0, 12);
        for (unsigned i = 0; i < 40; i++) put(&w, 0x55, 8);
        break;
    case 20:
        *name = "no end-of-block code";
        memset(c.lit, 8, 256);
        c.dist[0] = 1;
        dynamic_header(&w, 1, &c, 257, 1);
        for (unsigned i = 0; i < 100; i++) put_lit(&w, &c, i);
        *size = 100;
        break;
    case 21:
        *name = "a dynamic header's 14 bits at the input's end";
        block(&w, 0, 1);
        for (unsigned i = 0; i < 5; i++) put_lit(&w, &f, 200);
        put_lit(&w, &f, 256);
        block(&w, 1, 2);
        put(&w, 31, 5), put(&w, 0, 5), put(&w, 0, 4);
        *size = 5;
        break;
    case 22:
        *name = "a block header's 3 bits at the input's end";
        block(&w, 0, 1);
        for (unsigned i = 0; i < 3; i++) put_lit(&w, &f, 200);
        put_lit(&w, &f, 256);
        block(&w, 1, 3);
        *size = 3;
        break;
    case 23:
    case 24:
    case 25: {
        unsigned n = which == 25 ? 3 : 400, d = which == 24 ? 31 : 30;
        *name = which == 23 ? "distance code 30 after 400 literals"
              : which == 24 ? "distance code 31 after 400 literals"
                            : "distance code 30 after 3 literals";
        block(&w, 1, 1);
        for (unsigned i = 0; i < n; i++) put_lit(&w, &f, 97);
        match_symbols(&w, &f, 257, 0, d, 0);
        put_lit(&w, &f, 256);
        *size = n;
        pad(&w);
        break;
    }
    case 26:
        *name = "a match cut by the output's end, then literal/length code 286";
        block(&w, 1, 1);
        put_lit(&w, &f, 97);
        match(&w, &f, 10, 1);
        put_lit(&w, &f, 286);
        put_lit(&w, &f, 256);
        *size = 5;
        break;
    case 27:
        *name = "a match too far back once the output is full";
        block(&w, 1, 1);
        put_lit(&w, &f, 97), put_lit(&w, &f, 98);
        match(&w, &f, 3, 5);
        put_lit(&w, &f, 256);
        *size = 2;
        break;
    case 28: {
        // Then blocks that open with them, after a literal of 1 to 13 bits: every bit count a block's first symbol meets.
        *name = "48-bit symbols at every alignment";
        for (unsigned i = 0; i < 13; i++) c.lit[97 + i] = (uint8_t)(i + 1);
        c.lit[285] = 14, c.lit[284] = 15, c.lit[256] = 15;
        for (unsigned i = 0; i < 14; i++) c.dist[i] = (uint8_t)(i + 1);
        c.dist[28] = 15, c.dist[29] = 15;
        dynamic_header(&w, 0, &c, 286, 30);
        put_lit(&w, &c, 97);
        size_t out = 1;
        for (unsigned i = 0; i < 130; i++) match_symbols(&w, &c, 285, 0, 0, 0), out += 258;
        uint64_t state = 48;
        for (unsigned i = 0; i < 300; i++) {
            uint64_t r = next(&state);
            put_lit(&w, &c, 97 + (unsigned)(r % 13));
            unsigned lextra = (unsigned)(r >> 8) % 31;
            match_symbols(&w, &c, 284, lextra, 28 + (unsigned)(r >> 16) % 2, (unsigned)(r >> 24) % 8192);
            out += 1 + 227 + lextra;
        }
        for (unsigned b = 0; b < 26; b++) {
            put_lit(&w, &c, 97 + b % 13);
            put_lit(&w, &c, 256);
            dynamic_header(&w, b == 25, &c, 286, 30);
            for (unsigned i = 0; i < 3; i++) {
                uint64_t r = next(&state);
                unsigned lextra = (unsigned)(r >> 8) % 31;
                match_symbols(&w, &c, 284, lextra, 28 + (unsigned)(r >> 16) % 2, (unsigned)(r >> 24) % 8192);
                out += 227 + lextra;
            }
            out++;
        }
        put_lit(&w, &c, 256);
        *size = out;
        pad(&w);
        break;
    }
    case 29:
        *name = "a stored block between fixed blocks of 400 literals";
        block(&w, 0, 1);
        for (unsigned i = 0; i < 400; i++) put_lit(&w, &f, 97);
        put_lit(&w, &f, 256);
        block(&w, 0, 0);
        put(&w, 0, (8 - w.count) & 7);
        put(&w, 5, 16), put(&w, 0xFFFF ^ 5, 16);
        for (unsigned i = 0; i < 5; i++) put(&w, 0x30 + i, 8);
        block(&w, 1, 1);
        for (unsigned i = 0; i < 400; i++) put_lit(&w, &f, 98 + i % 3);
        put_lit(&w, &f, 256);
        *size = 805;
        pad(&w);
        break;
    default:
        *name = "an empty fixed block";
        block(&w, 1, 1);
        put_lit(&w, &f, 256);
        break;
    }
    return finish(&w);
}
