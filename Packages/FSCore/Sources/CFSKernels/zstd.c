// zstd frame decoding (RFC 8878), bounds-checked at every step: Btrfs zstd extents (roadmap 0013). Written from the RFC;
// tested against the reference implementation's output (the zstd CLI) and its golden decompression files. Pure: it reads
// `source`, writes `target` and the caller's workspace, keeps no state and allocates nothing.
#include "fskernels.h"
#include <string.h>

enum { BLOCK_MAX = 128 * 1024, HUF_LOG_MAX = 11, LL_MAX = 35, ML_MAX = 52, OF_MAX = 31 };

// One FSE decoding cell: the symbol, the bits to read for the next state and the baseline they are added to.
typedef struct { uint8_t symbol, bits; uint16_t baseline; } fse_cell;
typedef struct { uint8_t symbol, bits; } huf_cell;
// A sequence table's cell, decoded ahead: the next state's baseline and bits, and the symbol's own base value and extra bits
// (what LL_BASE/LL_BITS, ML_BASE/ML_BITS or 1 << code give), so a sequence reads no other table.
// On arm64 the kernel (kernels_zstd_arm64.S) reads the cell's width first, the bits it reads in all (state bits + extra
// bits), so that a sequence's bits are one sum; elsewhere the C loop reads the extra bits as they are (measured faster:
// the C loop's `width - bits` cost it a fifth on t1, docs/research/2026-10-30-compression-kernels.md).
#if defined(__aarch64__)
typedef struct { uint8_t width, bits; uint16_t baseline; uint32_t value; } seq_cell;
#define CELL_EXTRA(cell) ((uint32_t)(cell).width - (cell).bits)
#define SEQ_CELL(bits, extra, baseline, value) ((seq_cell){(uint8_t)((bits) + (extra)), (bits), (baseline), (value)})
#else
typedef struct { uint16_t baseline; uint8_t bits, extra; uint32_t value; } seq_cell;
#define CELL_EXTRA(cell) ((cell).extra)
#define SEQ_CELL(bits, extra, baseline, value) ((seq_cell){(baseline), (bits), (uint8_t)(extra), (value)})
#endif

typedef struct {
    uint8_t literals[BLOCK_MAX + 32];
    huf_cell huffman[1 << HUF_LOG_MAX];
    seq_cell ll[1 << 9], ml[1 << 9], of[1 << 8];
    uint32_t llLog, mlLog, ofLog, hufLog;
    int hasHuffman, hasLL, hasML, hasOF;
    int reference;  // the C sequence loop, not the arm64 kernel (fsk_ref_zstd_decompress_frame)
} zstd_workspace;

#if defined(__aarch64__)
// The arm64 sequence kernel's view of one block's sequences (kernels_zstd_arm64.S, which reads it at these offsets): the three
// tables, the bitstream (8 bytes or more), the literals, the output and the repeat offsets. It decodes and executes all
// `count` sequences (1 or more), leaves the stream used up exactly, and writes back `lit`, `at` and `rep`; 0, or -1 for every
// case where the C loop below returns -1. The trailing literals stay with the caller.
typedef struct {
    const seq_cell *ll, *of, *ml;
    const uint8_t *stream;
    size_t streamSize;
    const uint8_t *lit, *litEnd;
    uint8_t *base, *at, *end;
    size_t count;
    uint32_t rep[3];
    uint32_t llLog, ofLog, mlLog;
} zstd_sequences;
_Static_assert(__builtin_offsetof(zstd_sequences, streamSize) == 32 && __builtin_offsetof(zstd_sequences, base) == 56 &&
                   __builtin_offsetof(zstd_sequences, count) == 80 && __builtin_offsetof(zstd_sequences, rep) == 88 &&
                   __builtin_offsetof(zstd_sequences, llLog) == 100 && sizeof(seq_cell) == 8 &&
                   __builtin_offsetof(seq_cell, bits) == 1 && __builtin_offsetof(seq_cell, baseline) == 2 &&
                   __builtin_offsetof(seq_cell, value) == 4,
               "the layout kernels_zstd_arm64.S reads");
int32_t fsk_zstd_sequences(zstd_sequences *sequences);
#endif

size_t fsk_zstd_workspace_size(void) { return sizeof(zstd_workspace); }

// ---------------------------------------------------------------------------------------------------------------------------
// XXH64, for the optional content checksum (its low 32 bits).
static const uint64_t P1 = 0x9E3779B185EBCA87ULL, P2 = 0xC2B2AE3D27D4EB4FULL, P3 = 0x165667B19E3779F9ULL,
                      P4 = 0x85EBCA77C2B2AE63ULL, P5 = 0x27D4EB2F165667C5ULL;
static uint64_t rotl64(uint64_t x, int r) { return (x << r) | (x >> (64 - r)); }
static uint64_t load64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }
static uint32_t load32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint64_t xxh_round(uint64_t acc, uint64_t input) { return rotl64(acc + input * P2, 31) * P1; }
static uint64_t xxh_merge(uint64_t acc, uint64_t value) { return (acc ^ xxh_round(0, value)) * P1 + P4; }

static uint64_t xxh64(const uint8_t *p, size_t len) {
    const uint8_t *end = p + len;
    uint64_t h;
    if (len >= 32) {
        uint64_t v1 = P1 + P2, v2 = P2, v3 = 0, v4 = 0 - P1;
        while (end - p >= 32) {
            v1 = xxh_round(v1, load64(p)); v2 = xxh_round(v2, load64(p + 8));
            v3 = xxh_round(v3, load64(p + 16)); v4 = xxh_round(v4, load64(p + 24));
            p += 32;
        }
        h = rotl64(v1, 1) + rotl64(v2, 7) + rotl64(v3, 12) + rotl64(v4, 18);
        h = xxh_merge(h, v1); h = xxh_merge(h, v2); h = xxh_merge(h, v3); h = xxh_merge(h, v4);
    } else {
        h = P5;
    }
    h += len;
    while (end - p >= 8) { h ^= xxh_round(0, load64(p)); h = rotl64(h, 27) * P1 + P4; p += 8; }
    if (end - p >= 4) { h ^= (uint64_t)load32(p) * P1; h = rotl64(h, 23) * P2 + P3; p += 4; }
    while (p < end) { h ^= (*p++) * P5; h = rotl64(h, 11) * P1; }
    h ^= h >> 33; h *= P2; h ^= h >> 29; h *= P3; h ^= h >> 32;
    return h;
}

uint64_t fsk_xxh64(const uint8_t *bytes, size_t count) { return xxh64(bytes, count); }

// ---------------------------------------------------------------------------------------------------------------------------
// Bit streams. Forward (FSE table descriptions): bits from the low end of each byte, byte after byte. Backward (Huffman and
// sequence streams): written forward, read from the last bit back, after the highest set bit of the last byte (the end
// mark). `position` counts the bits not yet read; reading past the start gives zeros and makes it negative (an overflow,
// which the callers check).
static int highbit(uint32_t v) { return 31 - __builtin_clz(v); }

// A 64-bit container of the stream's bytes, the bits read so far counted from its top (`consumed`), and where it was loaded
// from (`ptr`, which moves back toward `start` on a reload). A stream shorter than 8 bytes sits at the container's top, the
// rest zero (`pad` bits that are not the stream's). `remaining()` is the bits not yet read: negative after an over-read.
typedef struct { const uint8_t *start, *ptr; uint64_t container; unsigned consumed, pad; } back_stream;

static int back_init(back_stream *s, const uint8_t *bytes, size_t size) {
    if (size == 0 || bytes[size - 1] == 0) return -1;
    s->start = bytes;
    if (size >= 8) {
        s->ptr = bytes + size - 8;
        s->container = load64(s->ptr);
        s->pad = 0;
    } else {
        uint64_t c = 0;
        for (size_t i = 0; i < size; i++) c |= (uint64_t)bytes[i] << (8 * i);
        s->ptr = bytes;
        s->pad = (unsigned)(8 * (8 - size));
        s->container = c << s->pad;
    }
    // The end mark and the zero bits above it are not data.
    s->consumed = (unsigned)(8 - highbit(bytes[size - 1]));
    return 0;
}

static inline __attribute__((always_inline)) int64_t back_remaining(const back_stream *s) {
    return 8 * (int64_t)(s->ptr - s->start) + 64 - (int64_t)s->pad - (int64_t)s->consumed;
}

// The next `count` (0 to 57) bits, not consumed; bits before the start read as zero (the container fills with zeros).
static inline __attribute__((always_inline)) uint64_t back_peek(const back_stream *s, int count) {
    return ((s->container << (s->consumed & 63)) >> 1) >> ((63 - count) & 63);
}

static inline __attribute__((always_inline)) uint64_t back_read(back_stream *s, int count) {
    uint64_t value = back_peek(s, count);
    s->consumed += (unsigned)count;
    return value;
}

// Moves the container back by the whole bytes read, as far as the start; after it at least 57 bits can be read (fewer near
// the start, where reads give zeros and `remaining()` goes negative).
static inline __attribute__((always_inline)) void back_reload(back_stream *s) {
    size_t behind = (size_t)(s->ptr - s->start);
    if (__builtin_expect(behind >= 8, 1)) {
        // At most 64 bits were read since the last reload (57 after it), so at most 8 bytes to step back.
        s->ptr -= s->consumed >> 3;
        s->consumed &= 7;
        s->container = load64(s->ptr);
        return;
    }
    if (s->consumed > 64) return;  // over-read: remaining() already says so
    size_t bytes = s->consumed >> 3;
    if (bytes > behind) bytes = behind;
    if (bytes == 0) return;
    s->ptr -= bytes;
    s->consumed -= (unsigned)(8 * bytes);
    s->container = load64(s->ptr);
}

// The sequences' reader: a bit position, each read one load at that position. Measured against the container above on the
// sequence loop, where a reload's load sits on the chain from one sequence to the next, this one is faster (docs/research/
// 2026-10-30-compression-kernels.md); the container is faster for Huffman streams.
typedef struct { const uint8_t *bytes; size_t size; int64_t position; } pos_stream;

static int pos_init(pos_stream *s, const uint8_t *bytes, size_t size) {
    if (size == 0 || bytes[size - 1] == 0) return -1;
    s->bytes = bytes;
    s->size = size;
    s->position = (int64_t)(size - 1) * 8 + highbit(bytes[size - 1]);
    return 0;
}

// The `count` (0 to 32) bits below `position`, without consuming them; bits before the start read as zero. One 8-byte load
// whenever the stream has 8 bytes: from the bits' byte, or from the stream's last 8 bytes near its end (where every backward
// stream starts).
// Bits near the start (or before it), or a stream under 8 bytes: one at a time, out of the hot path.
static __attribute__((noinline)) uint64_t pos_peek_slow(const pos_stream *s, int count) {
    int64_t low = s->position - count;
    uint64_t value = 0;
    for (int64_t bit = s->position - 1; bit >= low && bit >= 0; bit--) {
        value |= (uint64_t)((s->bytes[bit >> 3] >> (bit & 7)) & 1) << (bit - low);
    }
    return value & ((1ULL << count) - 1);
}

// The `count` (0 to 57) bits below `position`, not consumed; bits before the start read as zero. One 8-byte load whenever
// the stream has 8 bytes: from the bits' byte, or from the stream's last 8 bytes near its end (where every stream starts).
static inline __attribute__((always_inline)) uint64_t pos_peek(const pos_stream *s, int count) {
    if (count == 0) return 0;  // frequent (most literal and match codes have no extra bits): no load
    int64_t low = s->position - count;
    if (__builtin_expect(low < 0 || s->size < 8, 0)) return pos_peek_slow(s, count);
    size_t base = (size_t)(low >> 3);
    if (base > s->size - 8) base = s->size - 8;
    return (load64(s->bytes + base) >> (low - 8 * (int64_t)base)) & ((1ULL << count) - 1);
}

static inline __attribute__((always_inline)) uint64_t pos_read(pos_stream *s, int count) {
    uint64_t value = pos_peek(s, count);
    s->position -= count;
    return value;
}

// ---------------------------------------------------------------------------------------------------------------------------
// FSE: a table description (normalized counts, RFC 4.1.1) and the decoding table it spreads to.
static int fse_read_counts(const uint8_t *in, size_t size, int16_t *counts, int maxSymbol, int maxLog, uint32_t *log,
                           size_t *used) {
    size_t bit = 0, limit = size * 8;
#define FWD(n) ({ uint32_t v_ = 0; for (int i_ = 0; i_ < (n); i_++, bit++) \
        if (bit < limit) v_ |= (uint32_t)((in[bit >> 3] >> (bit & 7)) & 1) << i_; v_; })
#define PEEKF(n) ({ uint32_t v_ = 0; for (int i_ = 0; i_ < (n); i_++) { size_t b_ = bit + i_; \
        if (b_ < limit) v_ |= (uint32_t)((in[b_ >> 3] >> (b_ & 7)) & 1) << i_; } v_; })
    uint32_t accuracy = FWD(4) + 5;
    if ((int)accuracy > maxLog) return -1;
    int remaining = (1 << accuracy) + 1, threshold = 1 << accuracy, bits = accuracy + 1, symbol = 0;
    for (int i = 0; i <= maxSymbol; i++) counts[i] = 0;
    while (remaining > 1) {
        if (symbol > maxSymbol) return -1;
        int max = 2 * threshold - 1 - remaining, count;
        uint32_t value = PEEKF(bits);
        if ((int)(value & (threshold - 1)) < max) {
            count = value & (threshold - 1);
            bit += bits - 1;
        } else {
            count = value & (2 * threshold - 1);
            if (count >= threshold) count -= max;
            bit += bits;
        }
        count--;
        remaining -= count < 0 ? -count : count;
        counts[symbol++] = (int16_t)count;
        if (count == 0) {
            // A zero probability is followed by 2-bit repeat counts of more zeros, 3 meaning "and more".
            for (;;) {
                uint32_t repeat = FWD(2);
                symbol += repeat;
                if (symbol > maxSymbol + 1) return -1;
                if (repeat != 3) break;
            }
        }
        if (remaining < threshold) {
            if (remaining <= 1) break;
            bits = highbit(remaining) + 1;
            threshold = 1 << (bits - 1);
        }
        if (bit > limit) return -1;
    }
    if (remaining != 1 || bit > limit) return -1;
    *log = accuracy;
    *used = (bit + 7) / 8;
    return 0;
#undef FWD
#undef PEEKF
}

static int fse_build(fse_cell *table, const int16_t *counts, int maxSymbol, uint32_t log) {
    uint32_t size = 1u << log, high = size - 1;
    uint16_t next[64];
    for (int s = 0; s <= maxSymbol; s++) {
        if (counts[s] == -1) { table[high--].symbol = (uint8_t)s; next[s] = 1; }
        else next[s] = (uint16_t)counts[s];
    }
    uint32_t position = 0, step = (size >> 1) + (size >> 3) + 3;
    for (int s = 0; s <= maxSymbol; s++) {
        for (int i = 0; i < counts[s]; i++) {
            table[position].symbol = (uint8_t)s;
            do { position = (position + step) & (size - 1); } while (position > high);
        }
    }
    if (position != 0) return -1;  // the counts did not fill the table
    for (uint32_t u = 0; u < size; u++) {
        uint32_t state = next[table[u].symbol]++;
        uint32_t bits = log - highbit(state);
        table[u].bits = (uint8_t)bits;
        table[u].baseline = (uint16_t)((state << bits) - size);
    }
    return 0;
}

static void fse_rle(fse_cell *table, uint8_t symbol) { table[0] = (fse_cell){symbol, 0, 0}; }

// ---------------------------------------------------------------------------------------------------------------------------
// Huffman (RFC 4.2): the tree description, then 1 or 4 streams of literals.
static int huf_read(zstd_workspace *w, const uint8_t *in, size_t size, size_t *used) {
    if (size < 1) return -1;
    uint8_t weights[256];
    int count;
    uint32_t header = in[0];
    if (header < 128) {
        // FSE-compressed weights: two states over one backward stream, alternating, until it runs out.
        if (header + 1 > size) return -1;
        int16_t counts[16];
        uint32_t log;
        size_t descriptor;
        fse_cell table[1 << 6];
        if (fse_read_counts(in + 1, header, counts, 15, 6, &log, &descriptor)) return -1;
        if (fse_build(table, counts, 15, log)) return -1;
        back_stream s;
        if (descriptor > header || back_init(&s, in + 1 + descriptor, header - descriptor)) return -1;
        uint32_t state1 = (uint32_t)back_read(&s, log), state2 = (uint32_t)back_read(&s, log);
        if (back_remaining(&s) < 0) return -1;
        count = 0;
        for (;;) {
            back_reload(&s);
            if (count >= 255) return -1;
            weights[count++] = table[state1].symbol;
            state1 = table[state1].baseline + (uint32_t)back_read(&s, table[state1].bits);
            if (back_remaining(&s) < 0) { if (count >= 255) return -1; weights[count++] = table[state2].symbol; break; }
            if (count >= 255) return -1;
            weights[count++] = table[state2].symbol;
            state2 = table[state2].baseline + (uint32_t)back_read(&s, table[state2].bits);
            if (back_remaining(&s) < 0) { if (count >= 255) return -1; weights[count++] = table[state1].symbol; break; }
        }
        *used = 1 + header;
    } else {
        count = header - 127;
        size_t bytes = (size_t)(count + 1) / 2;
        if (1 + bytes > size) return -1;
        for (int i = 0; i < count; i++) weights[i] = (i & 1) ? in[1 + i / 2] & 15 : in[1 + i / 2] >> 4;
        *used = 1 + bytes;
    }
    // The last weight is implied: what brings the total to a power of two.
    uint32_t total = 0;
    for (int i = 0; i < count; i++) {
        if (weights[i]) total += 1u << (weights[i] - 1);
    }
    if (total == 0) return -1;
    uint32_t log = highbit(total) + 1;
    if (log > HUF_LOG_MAX) return -1;
    uint32_t rest = (1u << log) - total;
    if (rest & (rest - 1)) return -1;
    weights[count++] = (uint8_t)(highbit(rest) + 1);
    // Canonical codes: by weight, lowest first, then by symbol; each takes 2^(weight-1) cells of the table, which they fill
    // exactly (the implied weight made the total a power of two). Weights above 11 make the log above 11, refused above.
    uint32_t start[HUF_LOG_MAX + 2] = {0}, next = 0;
    for (int i = 0; i < count; i++) if (weights[i]) start[weights[i]]++;
    for (uint32_t weight = 1; weight <= log; weight++) {
        uint32_t current = next;
        next += start[weight] << (weight - 1);
        start[weight] = current;
    }
    for (int symbol = 0; symbol < count; symbol++) {
        uint32_t weight = weights[symbol];
        if (!weight) continue;
        uint32_t length = 1u << (weight - 1);
        for (uint32_t u = start[weight]; u < start[weight] + length; u++)
            w->huffman[u] = (huf_cell){(uint8_t)symbol, (uint8_t)(log + 1 - weight)};
        start[weight] += length;
    }
    w->hufLog = log;
    w->hasHuffman = 1;
    return 0;
}

static inline __attribute__((always_inline)) void huf_symbol(const zstd_workspace *w, back_stream *s, int log, uint8_t *out) {
    huf_cell cell = w->huffman[back_peek(s, log)];
    *out = cell.symbol;
    s->consumed += cell.bits;
}

static int huf_stream(const zstd_workspace *w, const uint8_t *in, size_t size, uint8_t *out, size_t count) {
    back_stream s;
    if (back_init(&s, in, size)) return -1;
    int log = (int)w->hufLog;
    for (size_t i = 0; i < count; i++) {
        if ((i & 3) == 0) back_reload(&s);  // four symbols of at most 11 bits between reloads
        huf_symbol(w, &s, log, out + i);
    }
    // An over-read decodes garbage, within bounds, and ends here: the stream must be used up exactly.
    return back_remaining(&s) == 0 ? 0 : -1;
}

// Four streams in lockstep (independent chains, so the core overlaps them), `segment` symbols each but the last, which
// decodes `last`; then each must be exactly used up, as one at a time.
static int huf_streams4(const zstd_workspace *w, const uint8_t *const in[4], const size_t size[4], uint8_t *out,
                        size_t segment, size_t last) {
    back_stream s[4];
    for (int i = 0; i < 4; i++) if (back_init(&s[i], in[i], size[i])) return -1;
    int log = (int)w->hufLog;
    size_t both = last < segment ? last : segment;
    for (size_t i = 0; i < both; i++) {
        if ((i & 3) == 0) for (int k = 0; k < 4; k++) back_reload(&s[k]);
        huf_symbol(w, &s[0], log, out + i);
        huf_symbol(w, &s[1], log, out + segment + i);
        huf_symbol(w, &s[2], log, out + 2 * segment + i);
        huf_symbol(w, &s[3], log, out + 3 * segment + i);
    }
    for (size_t i = both; i < segment; i++) {
        for (int k = 0; k < 3; k++) { back_reload(&s[k]); huf_symbol(w, &s[k], log, out + k * segment + i); }
    }
    return (back_remaining(&s[0]) | back_remaining(&s[1]) | back_remaining(&s[2]) | back_remaining(&s[3])) == 0 ? 0 : -1;
}

// ---------------------------------------------------------------------------------------------------------------------------
// The literals section (RFC 3.1.1.3.1): their bytes into the workspace.
static int read_literals(zstd_workspace *w, const uint8_t *in, size_t size, size_t *used, size_t *count) {
    if (size < 1) return -1;
    uint32_t type = in[0] & 3, format = (in[0] >> 2) & 3;
    size_t header, regenerated, compressed = 0;
    int streams = 1;
    if (type < 2) {
        if (format == 0 || format == 2) { header = 1; regenerated = in[0] >> 3; }
        else if (format == 1) { header = 2; if (size < 2) return -1; regenerated = (in[0] >> 4) + ((size_t)in[1] << 4); }
        else { header = 3; if (size < 3) return -1; regenerated = (in[0] >> 4) + ((size_t)in[1] << 4) + ((size_t)in[2] << 12); }
    } else {
        header = format < 2 ? 3 : format == 2 ? 4 : 5;
        if (size < header) return -1;
        uint64_t all = 0;
        for (size_t i = 0; i < header; i++) all |= (uint64_t)in[i] << (8 * i);
        int bits = format < 2 ? 10 : format == 2 ? 14 : 18;
        regenerated = (all >> 4) & ((1u << bits) - 1);
        compressed = (all >> (4 + bits)) & ((1u << bits) - 1);
        streams = format == 0 ? 1 : 4;
    }
    if (regenerated > BLOCK_MAX) return -1;
    *count = regenerated;
    if (type == 0) {
        if (header + regenerated > size) return -1;
        memcpy(w->literals, in + header, regenerated);
        *used = header + regenerated;
        return 0;
    }
    if (type == 1) {
        if (header + 1 > size) return -1;
        memset(w->literals, in[header], regenerated);
        *used = header + 1;
        return 0;
    }
    if (header + compressed > size) return -1;
    const uint8_t *data = in + header;
    size_t tree = 0;
    if (type == 2) {
        if (huf_read(w, data, compressed, &tree)) return -1;
    } else if (!w->hasHuffman) {
        return -1;  // treeless literals with no previous table
    }
    data += tree;
    size_t rest = compressed - tree;
    if (tree > compressed) return -1;
    if (streams == 1) {
        if (huf_stream(w, data, rest, w->literals, regenerated)) return -1;
    } else {
        if (rest < 6) return -1;
        size_t sizes[4] = {data[0] | (size_t)data[1] << 8, data[2] | (size_t)data[3] << 8, data[4] | (size_t)data[5] << 8, 0};
        if (sizes[0] + sizes[1] + sizes[2] > rest - 6) return -1;
        sizes[3] = rest - 6 - sizes[0] - sizes[1] - sizes[2];
        size_t segment = (regenerated + 3) / 4;
        if (3 * segment > regenerated) return -1;
        const uint8_t *streams[4] = {data + 6, data + 6 + sizes[0], data + 6 + sizes[0] + sizes[1],
                                     data + 6 + sizes[0] + sizes[1] + sizes[2]};
        if (huf_streams4(w, streams, sizes, w->literals, segment, regenerated - 3 * segment)) return -1;
    }
    *used = header + compressed;
    return 0;
}

// ---------------------------------------------------------------------------------------------------------------------------
// Sequences (RFC 3.1.1.3.2).
static const int16_t LL_DEFAULT[36] = {4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2,
                                       2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1};
static const int16_t ML_DEFAULT[53] = {1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                                       1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1};
static const int16_t OF_DEFAULT[29] = {1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1,
                                       1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1};
static const uint32_t LL_BASE[36] = {0,  1,  2,  3,  4,  5,  6,  7,  8,  9,   10,  11,  12,   13,   14,   15,   16,    18,
                                     20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536};
static const uint8_t LL_BITS[36] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1,
                                    1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};
static const uint32_t ML_BASE[53] = {3,  4,  5,  6,  7,  8,  9,  10, 11,  12,  13,  14,  15,   16,   17,   18,   19,    20,
                                     21, 22, 23, 24, 25, 26, 27, 28, 29,  30,  31,  32,  33,   34,   35,   37,   39,    41,
                                     43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539};
static const uint8_t ML_BITS[53] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                    0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};

// The sequence tables' symbols: base values and extra bits (offsets: 1 << code and code).
enum { LITERALS, OFFSETS, MATCHES };

static void seq_fill(seq_cell *table, const fse_cell *cells, uint32_t size, int kind) {
    for (uint32_t u = 0; u < size; u++) {
        uint32_t symbol = cells[u].symbol, value, extra;
        if (kind == LITERALS) { value = LL_BASE[symbol]; extra = LL_BITS[symbol]; }
        else if (kind == MATCHES) { value = ML_BASE[symbol]; extra = ML_BITS[symbol]; }
        else { value = 1u << symbol; extra = symbol; }
        table[u] = SEQ_CELL(cells[u].bits, extra, cells[u].baseline, value);
    }
}

// One table of the three: predefined (0), RLE (1), described (2) or the previous one (3).
static int read_table(int mode, const uint8_t *in, size_t size, size_t *used, seq_cell *table, uint32_t *log, int *has,
                      const int16_t *defaults, int defaultSymbols, int defaultLog, int maxSymbol, int maxLog, int kind) {
    fse_cell cells[1 << 9];
    *used = 0;
    switch (mode) {
        case 0:
            *log = defaultLog;
            if (fse_build(cells, defaults, defaultSymbols - 1, defaultLog)) return -1;
            break;
        case 1:
            if (size < 1 || in[0] > maxSymbol) return -1;
            fse_rle(cells, in[0]);
            *log = 0;
            *used = 1;
            break;
        case 2: {
            int16_t counts[64];
            if (fse_read_counts(in, size, counts, maxSymbol, maxLog, log, used)) return -1;
            if (fse_build(cells, counts, maxSymbol, *log)) return -1;
            break;
        }
        default: return *has ? 0 : -1;
    }
    *has = 1;
    seq_fill(table, cells, 1u << *log, kind);
    return 0;
}

typedef struct { uint8_t *base, *at, *end; } output;

// 16 bytes from `from` to `to`, with no call: the copies' unit.
static inline __attribute__((always_inline)) void copy16(uint8_t *to, const uint8_t *from) {
    uint64_t a = load64(from), b = load64(from + 8);
    memcpy(to, &a, 8);
    memcpy(to + 8, &b, 8);
}

static inline __attribute__((always_inline)) int copy_match(output *o, size_t offset, size_t length) {
    if (offset == 0 || offset > (size_t)(o->at - o->base) || length > (size_t)(o->end - o->at)) return -1;
    uint8_t *to = o->at, *end = o->at + length;
    const uint8_t *from = to - offset;
    if (offset >= 16 && (size_t)(o->end - end) >= 16) {
        // 16 back or more: 16-byte moves front to back, each reading bytes already final; the last may run past the match,
        // within the room left (bytes past the cursor are rewritten, or past the result and unspecified). The first move
        // unconditionally, so the matches of 16 or fewer (most) take no loop.
        copy16(to, from);
        to += 16;
        from += 16;
        while (to < end) { copy16(to, from); to += 16; from += 16; }
    } else {
        for (; to < end; to++, from++) *to = *from;
    }
    o->at = end;
    return 0;
}

// `count` literals: 16-byte moves when the room allows their overrun (the literals buffer has 32 bytes of slack).
static inline __attribute__((always_inline)) void copy_literals(output *o, const uint8_t *from, size_t count) {
    uint8_t *to = o->at, *end = o->at + count;
    if ((size_t)(o->end - end) >= 16) {
        copy16(to, from);  // most runs are 16 or fewer: no loop for them
        to += 16;
        from += 16;
        while (to < end) { copy16(to, from); to += 16; from += 16; }
    } else {
        memcpy(to, from, count);
    }
    o->at = end;
}

static int sequences(zstd_workspace *w, const uint8_t *in, size_t size, size_t literals, output *o, uint32_t *rep) {
    if (size < 1) return -1;
    size_t at = 0, count = in[at++];
    if (count >= 128) {
        if (count < 255) { if (at + 1 > size) return -1; count = ((count - 128) << 8) + in[at++]; }
        else { if (at + 2 > size) return -1; count = in[at] + ((size_t)in[at + 1] << 8) + 0x7F00; at += 2; }
    }
    const uint8_t *lit = w->literals, *litEnd = w->literals + literals;
    if (count == 0) {
        if (at != size || literals > (size_t)(o->end - o->at)) return -1;
        memcpy(o->at, lit, literals);
        o->at += literals;
        return 0;
    }
    if (at + 1 > size) return -1;
    uint32_t modes = in[at++];
    if (modes & 3) return -1;
    size_t used;
    if (read_table(modes >> 6, in + at, size - at, &used, w->ll, &w->llLog, &w->hasLL, LL_DEFAULT, 36, 6, LL_MAX, 9, LITERALS)) return -1;
    at += used;
    if (read_table((modes >> 4) & 3, in + at, size - at, &used, w->of, &w->ofLog, &w->hasOF, OF_DEFAULT, 29, 5, OF_MAX, 8, OFFSETS)) return -1;
    at += used;
    if (read_table((modes >> 2) & 3, in + at, size - at, &used, w->ml, &w->mlLog, &w->hasML, ML_DEFAULT, 53, 6, ML_MAX, 9, MATCHES)) return -1;
    at += used;
    if (at > size) return -1;
#if defined(__aarch64__)
    if (!w->reference && size - at >= 8) {
        zstd_sequences k = {w->ll, w->of, w->ml, in + at, size - at, lit, litEnd, o->base, o->at, o->end, count,
                            {rep[0], rep[1], rep[2]}, w->llLog, w->ofLog, w->mlLog};
        if (fsk_zstd_sequences(&k)) return -1;
        memcpy(rep, k.rep, sizeof k.rep);
        lit = k.lit;
        o->at = k.at;
        goto trailing;
    }
#endif
    pos_stream s;
    if (pos_init(&s, in + at, size - at)) return -1;
    uint32_t llState = (uint32_t)pos_read(&s, w->llLog), ofState = (uint32_t)pos_read(&s, w->ofLog),
             mlState = (uint32_t)pos_read(&s, w->mlLog);
    for (size_t n = 0; n < count; n++) {
        // The cells carry each symbol's base value and extra bits: offset bits first, then match, then literals. (Reading the
        // three fields, or the three states, in one read measured slower: docs/research/2026-10-30-compression-kernels.md.)
        seq_cell lc = w->ll[llState], oc = w->of[ofState], mc = w->ml[mlState];
        size_t offset = oc.value + pos_read(&s, CELL_EXTRA(oc));
        size_t match = mc.value + pos_read(&s, CELL_EXTRA(mc));
        size_t lits = lc.value + pos_read(&s, CELL_EXTRA(lc));
        if (offset > 3) {
            rep[2] = rep[1]; rep[1] = rep[0]; rep[0] = (uint32_t)(offset - 3);
        } else {
            size_t index = offset - 1 + (lits == 0);
            if (index == 1) { uint32_t t = rep[1]; rep[1] = rep[0]; rep[0] = t; }
            else if (index == 2) { uint32_t t = rep[2]; rep[2] = rep[1]; rep[1] = rep[0]; rep[0] = t; }
            else if (index == 3) { uint32_t t = rep[0] - 1; if (t == 0) return -1; rep[2] = rep[1]; rep[1] = rep[0]; rep[0] = t; }
        }
        if (lits > (size_t)(litEnd - lit) || lits > (size_t)(o->end - o->at)) return -1;
        copy_literals(o, lit, lits);
        lit += lits;
        if (copy_match(o, rep[0], match)) return -1;
        if (n + 1 < count) {
            // The three states (literals, match, offset, at most 26 bits) in one read.
            llState = lc.baseline + (uint32_t)pos_read(&s, lc.bits);
            mlState = mc.baseline + (uint32_t)pos_read(&s, mc.bits);
            ofState = oc.baseline + (uint32_t)pos_read(&s, oc.bits);
        }
    }
    // An over-read decodes garbage, every copy still bounded, and ends here: the stream must be used up exactly.
    if (s.position != 0) return -1;
#if defined(__aarch64__)
trailing:;
#endif
    size_t rest = (size_t)(litEnd - lit);
    if (rest > (size_t)(o->end - o->at)) return -1;
    memcpy(o->at, lit, rest);
    o->at += rest;
    return 0;
}

// ---------------------------------------------------------------------------------------------------------------------------
static int64_t frame(const uint8_t *source, size_t count, uint8_t *target, size_t capacity, zstd_workspace *w,
                     size_t *consumed) {
    w->hasHuffman = w->hasLL = w->hasML = w->hasOF = 0;
    size_t at = 0;
    if (count < 4) return -1;
    uint32_t magic = load32(source);
    if ((magic & 0xFFFFFFF0u) == 0x184D2A50u) {
        // A skippable frame: its length, then data nobody decodes.
        if (count < 8) return -1;
        uint64_t length = load32(source + 4);
        if (length > count - 8) return -1;
        *consumed = 8 + (size_t)length;
        return 0;
    }
    if (magic != 0xFD2FB528u) return -1;
    at = 4;
    if (at + 1 > count) return -1;
    uint32_t descriptor = source[at++];
    uint32_t sizeFlag = descriptor >> 6, single = (descriptor >> 5) & 1, checksum = (descriptor >> 2) & 1,
             dictionaryFlag = descriptor & 3;
    if (descriptor & 8) return -1;  // reserved
    uint64_t windowSize = 0;
    if (!single) {
        if (at + 1 > count) return -1;
        uint32_t window = source[at++], log = (window >> 3) + 10;
        if (log > 31) return -1;  // as the reference (ZSTD_WINDOWLOG_MAX): no window past 2 GiB
        windowSize = (1ULL << log) + ((1ULL << log) >> 3) * (window & 7);
    }
    static const int dictionaryBytes[4] = {0, 1, 2, 4};
    if (at + dictionaryBytes[dictionaryFlag] > count) return -1;
    uint32_t dictionary = 0;
    for (int i = 0; i < dictionaryBytes[dictionaryFlag]; i++) dictionary |= (uint32_t)source[at + i] << (8 * i);
    at += dictionaryBytes[dictionaryFlag];
    if (dictionary != 0) return -2;  // dictionaries: not used by Btrfs, refused
    static const int sizeBytes[4] = {0, 2, 4, 8};
    int fcsBytes = sizeFlag == 0 && single ? 1 : sizeBytes[sizeFlag];
    if (at + fcsBytes > count) return -1;
    uint64_t contentSize = 0;
    int hasSize = fcsBytes > 0;
    for (int i = 0; i < fcsBytes; i++) contentSize |= (uint64_t)source[at + i] << (8 * i);
    if (fcsBytes == 2) contentSize += 256;
    at += fcsBytes;
    if (hasSize && contentSize > capacity) return -1;
    if (single) windowSize = contentSize;
    // Block_Maximum_Size: no compressed block, and no compressed block's output, larger than the window or 128 KiB. Raw and
    // RLE blocks are held only to the capacity, as the reference decoder (and so the Linux kernel) holds them.
    size_t blockMax = windowSize < BLOCK_MAX ? (size_t)windowSize : BLOCK_MAX;
    output o = {target, target, target + capacity};
    uint32_t rep[3] = {1, 4, 8};
    for (;;) {
        if (at + 3 > count) return -1;
        uint32_t header = source[at] | (uint32_t)source[at + 1] << 8 | (uint32_t)source[at + 2] << 16;
        at += 3;
        uint32_t last = header & 1, type = (header >> 1) & 3, size = header >> 3;
        if (type == 3 || (type == 2 && size > blockMax)) return -1;
        if (type == 0) {
            if (at + size > count || size > (size_t)(o.end - o.at)) return -1;
            memcpy(o.at, source + at, size);
            o.at += size;
            at += size;
        } else if (type == 1) {
            if (at + 1 > count || size > (size_t)(o.end - o.at)) return -1;
            memset(o.at, source[at], size);
            o.at += size;
            at += 1;
        } else {
            if (at + size > count) return -1;
            size_t literalsUsed, literals;
            if (read_literals(w, source + at, size, &literalsUsed, &literals)) return -1;
            output block = o;
            if ((size_t)(block.end - block.at) > blockMax) block.end = block.at + blockMax;
            if (sequences(w, source + at + literalsUsed, size - literalsUsed, literals, &block, rep)) return -1;
            o.at = block.at;
            at += size;
        }
        if (last) break;
    }
    size_t produced = (size_t)(o.at - target);
    if (hasSize && produced != contentSize) return -1;
    if (checksum) {
        if (at + 4 > count) return -1;
        if ((uint32_t)xxh64(target, produced) != load32(source + at)) return -1;
        at += 4;
    }
    *consumed = at;
    return (int64_t)produced;
}

int64_t fsk_zstd_decompress_frame(const uint8_t *source, size_t count, uint8_t *target, size_t capacity, void *workspace,
                                  size_t *consumed) {
    zstd_workspace *w = (zstd_workspace *)workspace;
    w->reference = 0;
    return frame(source, count, target, capacity, w, consumed);
}

// The same decoder with the C sequence loop on every target: the reference the arm64 kernel is tested against.
int64_t fsk_ref_zstd_decompress_frame(const uint8_t *source, size_t count, uint8_t *target, size_t capacity,
                                      void *workspace, size_t *consumed);
int64_t fsk_ref_zstd_decompress_frame(const uint8_t *source, size_t count, uint8_t *target, size_t capacity,
                                      void *workspace, size_t *consumed) {
    zstd_workspace *w = (zstd_workspace *)workspace;
    w->reference = 1;
    return frame(source, count, target, capacity, w, consumed);
}
