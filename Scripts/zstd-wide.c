// A zstd frame whose sequences read more than 57 bits each and are not the last of their block (roadmap 0013): the arm64
// sequence kernel decodes those apart (kernels_zstd_arm64.S, Lzs_wide), and no CLI frame holds one. libzstd encodes the
// sequences given (ZSTD_compressSequences): blocks of 600 small ones and, three times each, a wide one (16384 + 14 bits of
// literals, 16387 + 14 bits of match, 13 bits of offset, and its rare codes' states, about 7 bits each) followed by a medium
// one (11, 11 and 13 bits, and its states): more bits than the wide one's states leave in the kernel's window. Then blocks
// of 4200 small ones (the most for the tables' 9-bit accuracy) and 20 short wide ones far back (7 + 8 bits of lengths, 21
// of offset), whose codes then take 2 or 3 cells of the table each: cells whose states start above 0, which a mix-up of
// the three tables' states would show. A run of 2.2 MB first, to reach that far back. Writes wide-sequences.zst and its
// original, .raw, into the directory given (zstd by default).
#define ZSTD_STATIC_LINKING_ONLY
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zstd.h>

static unsigned long long seed = 0x5EED;
static unsigned next(void) {
    seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
    return (unsigned)(seed >> 33);
}

int main(int argc, char **argv) {
    const char *dir = argc > 1 ? argv[1] : "zstd";
    enum { SMALL = 2400, FAR = 2 * 4220, CAP = 4 << 20 };
    static ZSTD_Sequence seqs[20 + SMALL + 16 + FAR + 16];
    static unsigned char src[CAP], dst[CAP], back[CAP];
    size_t count = 0, size = 0;
    src[size++] = 'x';
    for (int i = 0; i < 17; i++) {
        unsigned lits = i == 0 ? 1 : 0, match = 131072 - lits;
        memset(src + size, 'x', match);
        size += match;
        seqs[count++] = (ZSTD_Sequence){1, lits, match, 0};
        seqs[count++] = (ZSTD_Sequence){0, 0, 0, 0};
    }
    for (int i = 0; i < SMALL; i++) {
        // Small: 1 to 2 literals and a match of 4 to 5, 1 to 4 back. Three times a block, a wide one (more than 57 bits),
        // then a medium one (about 50 bits, more than a wide one leaves in the window).
        int kind = i % 200 == 100 ? 2 : i % 200 == 101 ? 1 : 0;
        unsigned lits = kind == 2 ? 16384 + next() % 512 : kind == 1 ? 2048 + next() % 256 : 1 + next() % 2;
        unsigned match = kind == 2 ? 16387 + next() % 512 : kind == 1 ? 2051 + next() % 256 : 4 + next() % 2;
        unsigned offset = kind ? 8200 + next() % 1000 : 1 + next() % 4;
        if (size + lits < offset) offset = 1;
        for (unsigned k = 0; k < lits; k++) src[size++] = (unsigned char)('a' + next() % 20);
        for (unsigned k = 0; k < match; k++, size++) src[size] = src[size - offset];
        seqs[count++] = (ZSTD_Sequence){offset, lits, match, 0};
        if (i % 600 == 599) seqs[count++] = (ZSTD_Sequence){0, 0, 0, 0};  // a block ends (explicit delimiters)
    }
    for (int i = 0; i < FAR; i++) {
        int far = i % 4220 % 211 == 105;
        unsigned lits = far ? 128 + next() % 128 : 1 + next() % 2;
        unsigned match = far ? 259 + next() % 256 : 4 + next() % 2;
        unsigned offset = far ? (1u << 21) + next() % (1u << 19) : 1 + next() % 4;
        for (unsigned k = 0; k < lits; k++) src[size++] = (unsigned char)('a' + next() % 20);
        for (unsigned k = 0; k < match; k++, size++) src[size] = src[size - offset];
        seqs[count++] = (ZSTD_Sequence){offset, lits, match, 0};
        if (i % 4220 == 4219) seqs[count++] = (ZSTD_Sequence){0, 0, 0, 0};
    }
    ZSTD_CCtx *cctx = ZSTD_createCCtx();
    ZSTD_CCtx_setParameter(cctx, ZSTD_c_blockDelimiters, ZSTD_sf_explicitBlockDelimiters);
    ZSTD_CCtx_setParameter(cctx, ZSTD_c_validateSequences, 1);
    ZSTD_CCtx_setParameter(cctx, ZSTD_c_checksumFlag, 1);
    ZSTD_CCtx_setParameter(cctx, ZSTD_c_windowLog, 22);
    size_t n = ZSTD_compressSequences(cctx, dst, CAP, seqs, count, src, size);
    if (ZSTD_isError(n)) { fprintf(stderr, "zstd-wide: %s\n", ZSTD_getErrorName(n)); return 1; }
    size_t m = ZSTD_decompress(back, CAP, dst, n);
    if (ZSTD_isError(m) || m != size || memcmp(back, src, size)) { fprintf(stderr, "zstd-wide: no round trip\n"); return 1; }
    char path[4096];
    snprintf(path, sizeof path, "%s/wide-sequences.zst", dir);
    FILE *f = fopen(path, "wb");
    if (!f || fwrite(dst, 1, n, f) != n || fclose(f)) return 1;
    snprintf(path, sizeof path, "%s/wide-sequences.raw", dir);
    f = fopen(path, "wb");
    if (!f || fwrite(src, 1, size, f) != size || fclose(f)) return 1;
    ZSTD_freeCCtx(cctx);
    return 0;
}
