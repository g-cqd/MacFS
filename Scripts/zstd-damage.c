// Damaged zstd frames for the decoder's tests (roadmap 0013): each input frame changed a few ways (a byte flipped, set,
// a cut), deterministically, written as damaged/NNNNN.zst. The corpus script then records the reference decoder's verdict.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

static uint64_t state = 20261030;
static uint64_t next(void) { state = state * 6364136223846793005ULL + 1442695040888963407ULL; return state >> 33; }

int main(int argc, char **argv) {
    int out = 0;
    for (int a = 1; a < argc; a++) {
        FILE *f = fopen(argv[a], "rb");
        if (!f) continue;
        fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
        if (n < 8) { fclose(f); continue; }
        uint8_t *bytes = malloc(n), *copy = malloc(n);
        if (fread(bytes, 1, n, f) != (size_t)n) return 1;
        fclose(f);
        for (int trial = 0; trial < 6; trial++) {
            memcpy(copy, bytes, n);
            long length = n;
            switch (trial % 3) {
                case 0: copy[next() % n] ^= (uint8_t)(1 << (next() % 8)); break;
                case 1: copy[next() % n] = (uint8_t)next(); break;
                default: length = 1 + next() % (n - 1);
            }
            char name[64];
            snprintf(name, sizeof name, "damaged/%05d.zst", out++);
            FILE *o = fopen(name, "wb");
            fwrite(copy, 1, length, o);
            fclose(o);
        }
        free(bytes); free(copy);
    }
    return 0;
}
