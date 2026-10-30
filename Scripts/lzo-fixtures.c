// Built and run inside the container by make-test-images.inner.sh: LZO1X streams written by liblzo2, the reference
// implementation, with their originals, for Tests/BtrfsTests/LZO1XTests (docs/conformance/btrfs.md).
#include <lzo/lzo1x.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void emit(const char *name, const unsigned char *data, lzo_uint size, int best) {
    static unsigned char work[LZO1X_999_MEM_COMPRESS];
    unsigned char *out = malloc(size + size / 16 + 64 + 3);
    lzo_uint written = 0;
    if (best) lzo1x_999_compress(data, size, out, &written, work);
    else lzo1x_1_compress(data, size, out, &written, work);
    char path[256];
    snprintf(path, sizeof path, "lzo/%s-%s.lzo", name, best ? "999" : "1");
    FILE *f = fopen(path, "wb"); fwrite(out, 1, written, f); fclose(f);
    snprintf(path, sizeof path, "lzo/%s-%s.raw", name, best ? "999" : "1");
    f = fopen(path, "wb"); fwrite(data, 1, size, f); fclose(f);
    free(out);
}

int main(void) {
    if (lzo_init() != LZO_E_OK) return 1;
    enum { max = 65536 };
    static unsigned char text[max], random[max], zeros[max], mixed[max];
    unsigned state = 12345;
    for (int i = 0; i < max; i++) {
        text[i] = "the quick brown fox jumps over the lazy dog 0123456789\n"[(i * 7 + i / 64) % 55];
        state = state * 1103515245u + 12345u;
        random[i] = (unsigned char)(state >> 16);
        mixed[i] = (i / 300) % 2 ? random[i] : text[i % 97];
    }
    const lzo_uint sizes[] = {1, 2, 3, 4, 15, 16, 17, 255, 256, 1000, 4096, 65536};
    for (unsigned s = 0; s < sizeof sizes / sizeof *sizes; s++) {
        for (int best = 0; best <= 1; best++) {
            char name[64];
            snprintf(name, sizeof name, "text-%lu", (unsigned long)sizes[s]); emit(name, text, sizes[s], best);
            snprintf(name, sizeof name, "random-%lu", (unsigned long)sizes[s]); emit(name, random, sizes[s], best);
            snprintf(name, sizeof name, "zeros-%lu", (unsigned long)sizes[s]); emit(name, zeros, sizes[s], best);
            snprintf(name, sizeof name, "mixed-%lu", (unsigned long)sizes[s]); emit(name, mixed, sizes[s], best);
        }
    }
    return 0;
}
