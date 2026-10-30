// The reference decoder's verdict on each zstd file named (roadmap 0013): libzstd's one-shot ZSTD_decompress into an 8 MiB
// buffer, as MacFS decodes an extent into its own flat buffer. Prints name<TAB>"ok" (writing name.out) or name<TAB>"error".
// With --flips: for every bit of every byte of each file, the verdict on the file with that bit flipped, as
// name<TAB>byte<TAB>bit<TAB>"error", or <TAB>"ok"<TAB>length<TAB>XXH64 of the output (hex).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define XXH_STATIC_LINKING_ONLY
#define XXH_INLINE_ALL
#include <zstd.h>
#include "xxhash.h"

int main(int argc, char **argv) {
    size_t capacity = 8u << 20;
    void *out = malloc(capacity);
    int flips = argc > 1 && strcmp(argv[1], "--flips") == 0;
    for (int a = 1 + flips; a < argc; a++) {
        FILE *f = fopen(argv[a], "rb");
        if (!f) return 1;
        fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
        void *in = malloc(n ? n : 1);
        if (fread(in, 1, n, f) != (size_t)n) return 1;
        fclose(f);
        const char *name = argv[a];
        for (const char *p = argv[a]; *p; p++) if (*p == '/') name = p + 1;
        if (flips) {
            unsigned char *bytes = in;
            for (long byte = 0; byte < n; byte++) {
                for (int bit = 0; bit < 8; bit++) {
                    bytes[byte] ^= (unsigned char)(1 << bit);
                    size_t r = ZSTD_decompress(out, capacity, in, n);
                    bytes[byte] ^= (unsigned char)(1 << bit);
                    if (ZSTD_isError(r)) printf("%s\t%ld\t%d\terror\n", name, byte, bit);
                    else printf("%s\t%ld\t%d\tok\t%zu\t%016llx\n", name, byte, bit, r, (unsigned long long)XXH64(out, r, 0));
                }
            }
            free(in);
            continue;
        }
        size_t result = ZSTD_decompress(out, capacity, in, n);
        if (ZSTD_isError(result)) {
            printf("%s\terror\n", name);
        } else {
            char path[4096];
            snprintf(path, sizeof path, "%s.out", argv[a]);
            FILE *o = fopen(path, "wb");
            fwrite(out, 1, result, o);
            fclose(o);
            printf("%s\tok\n", name);
        }
        free(in);
    }
    return 0;
}
