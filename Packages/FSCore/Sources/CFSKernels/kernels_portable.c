// The portable kernels for targets without kernels_arm64.S (x86_64), and the references the arm64 kernels are tested
// against: built on every target as fsk_ref_ntfs_apply_fixups, fsk_ref_lznt1_decompress and fsk_ref_lzo1x_decompress.
#include "fskernels.h"

int32_t fsk_ref_ntfs_apply_fixups(uint8_t *record, size_t size, size_t stride);
int32_t fsk_ref_lznt1_decompress(const uint8_t *source, size_t count, uint8_t *target, size_t capacity);
int64_t fsk_ref_lzo1x_decompress(const uint8_t *source, size_t count, uint8_t *target, size_t capacity);

static uint16_t load16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }

int32_t fsk_ref_ntfs_apply_fixups(uint8_t *record, size_t size, size_t stride) {
    if (size < 8 || stride < 2) return -1;
    size_t offset = load16(record + 4), entries = load16(record + 6);
    if (entries == 0 || (offset & 1u) || size % stride != 0) return -1;
    if (entries - 1 != size / stride || offset + entries * 2 > size) return -1;
    uint16_t usn = load16(record + offset);
    for (size_t i = 1; i < entries; i++) {
        uint8_t *tail = record + i * stride - 2;
        if (load16(tail) != usn) return -2;
        tail[0] = record[offset + 2 * i];
        tail[1] = record[offset + 2 * i + 1];
    }
    return 0;
}

// LZNT1, byte by byte: the reference for the arm64 kernel (ntfs-3g's ntfs_decompress, every bound checked).
int32_t fsk_ref_lznt1_decompress(const uint8_t *source, size_t count, uint8_t *target, size_t capacity) {
    size_t position = 0, chunk = 0;
    while (position + 2 <= count && chunk < capacity) {
        size_t header = load16(source + position);
        if (header == 0) break;
        size_t end = position + (header & 0x0FFF) + 3, limit = chunk + 4096;
        if (end > count || limit > capacity) return -1;
        position += 2;
        size_t written = chunk;
        if (!(header & 0x8000)) {
            if (end - position != 4096) return -1;
            for (size_t i = 0; i < 4096; i++) target[chunk + i] = source[position + i];
            written = limit;
        } else {
            while (position < end) {
                unsigned flags = source[position++];
                for (int token = 0; token < 8 && position < end; token++, flags >>= 1) {
                    if (!(flags & 1)) {
                        if (written >= limit) return -1;
                        target[written++] = source[position++];
                        continue;
                    }
                    if (position + 2 > end) return -1;
                    size_t value = load16(source + position);
                    position += 2;
                    unsigned shift = 0;
                    for (size_t reach = written - chunk - 1; written > chunk && reach >= 0x10; reach >>= 1) shift++;
                    size_t distance = (value >> (12 - shift)) + 1, length = (value & (0x0FFFu >> shift)) + 3;
                    if (distance > written - chunk || length > limit - written) return -1;
                    for (size_t i = 0; i < length; i++, written++) target[written] = target[written - distance];
                }
            }
        }
        while (written < limit) target[written++] = 0;
        position = end;
        chunk = limit;
    }
    while (chunk < capacity) target[chunk++] = 0;
    return 0;
}

// LZO1X, byte by byte: the reference for the arm64 kernel (Linux's lzo1x_decompress_safe; the Swift decoder it replaces).
typedef struct { const uint8_t *in; size_t count, ip; uint8_t *out; size_t capacity, op; } lzo_state;

static int lzo_next(lzo_state *s, size_t *value) {
    if (s->ip >= s->count) return -1;
    *value = s->in[s->ip++];
    return 0;
}

// A length continued by zero bytes, each worth 255, then one non-zero byte.
static int lzo_extended(lzo_state *s, size_t base, size_t *value) {
    size_t total = base;
    for (;;) {
        if (s->ip >= s->count) return -1;
        if (s->in[s->ip] != 0) break;
        s->ip++;
        total += 255;
        if (total >= (1u << 24)) return -1;
    }
    size_t last;
    if (lzo_next(s, &last)) return -1;
    *value = total + last;
    return 0;
}

static int lzo_literals(lzo_state *s, size_t n) {
    if (n > s->capacity - s->op || n > s->count - s->ip) return -1;
    for (size_t i = 0; i < n; i++) s->out[s->op++] = s->in[s->ip++];
    return 0;
}

static int lzo_match(lzo_state *s, size_t distance, size_t n) {
    if (distance < 1 || distance > s->op || n > s->capacity - s->op) return -1;
    for (size_t i = 0; i < n; i++, s->op++) s->out[s->op] = s->out[s->op - distance];
    return 0;
}

int64_t fsk_ref_lzo1x_decompress(const uint8_t *source, size_t count, uint8_t *target, size_t capacity) {
    lzo_state s = {source, count, 0, target, capacity, 0};
    size_t state = 0, instruction, low, word, n;
    if (lzo_next(&s, &instruction)) return -1;
    if (instruction > 17) {
        n = instruction - 17;
        if (lzo_literals(&s, n)) return -1;
        state = n < 4 ? n : 4;
        if (lzo_next(&s, &instruction)) return -1;
    }
    for (;;) {
        size_t following = 0;
        if (instruction < 16) {
            if (state == 0) {
                n = instruction;
                if (n == 0 && lzo_extended(&s, 15, &n)) return -1;
                if (lzo_literals(&s, n + 3)) return -1;
                state = 4;
                if (lzo_next(&s, &instruction)) return -1;
                continue;
            }
            following = instruction & 3;
            if (lzo_next(&s, &low)) return -1;
            if (state != 4) {
                if (lzo_match(&s, 1 + (instruction >> 2) + (low << 2), 2)) return -1;
            } else if (lzo_match(&s, 1 + 0x0800 + (instruction >> 2) + (low << 2), 3)) return -1;
        } else if (instruction >= 64) {
            following = instruction & 3;
            if (lzo_next(&s, &low)) return -1;
            if (lzo_match(&s, 1 + ((instruction >> 2) & 7) + (low << 3), (instruction >> 5) + 1)) return -1;
        } else if (instruction >= 32) {
            n = instruction & 31;
            if (n == 0 && lzo_extended(&s, 31, &n)) return -1;
            if (lzo_next(&s, &low) || lzo_next(&s, &word)) return -1;
            word = low | word << 8;
            following = word & 3;
            if (lzo_match(&s, 1 + (word >> 2), n + 2)) return -1;
        } else {
            n = instruction & 7;
            if (n == 0 && lzo_extended(&s, 7, &n)) return -1;
            if (lzo_next(&s, &low) || lzo_next(&s, &word)) return -1;
            word = low | word << 8;
            following = word & 3;
            size_t distance = ((instruction & 8) << 11) + (word >> 2);
            if (distance == 0) break;  // the end marker
            if (lzo_match(&s, distance + 0x4000, n + 2)) return -1;
        }
        state = following;
        if (lzo_literals(&s, following)) return -1;
        if (lzo_next(&s, &instruction)) return -1;
    }
    return (int64_t)s.op;
}

#if !defined(__aarch64__)
int64_t fsk_lzo1x_decompress(const uint8_t *source, size_t count, uint8_t *target, size_t capacity) {
    return fsk_ref_lzo1x_decompress(source, count, target, capacity);
}

int32_t fsk_lznt1_decompress(const uint8_t *source, size_t count, uint8_t *target, size_t capacity) {
    return fsk_ref_lznt1_decompress(source, count, target, capacity);
}

int32_t fsk_ntfs_apply_fixups(uint8_t *record, size_t size, size_t stride) {
    return fsk_ref_ntfs_apply_fixups(record, size, stride);
}
#endif
