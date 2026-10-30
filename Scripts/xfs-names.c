// Names for the XFS hashed-lookup image (roadmap 0037), each a hard link the kernel makes, the i-th to TARGETS/t(i mod N):
// few inodes, yet a lookup that finds the wrong entry finds the wrong inode.
//
//   xfs-names plain DIR COUNT TARGETS N     names n0, n1, ... n(COUNT-1)
//   xfs-names collide DIR COUNT TARGETS N   8-byte names of [0-9A-Za-z] that all take the same xfs_da_hashname, 0x1C1C3870:
//                                           one hash run across several leaf blocks, which a lookup must follow
//
// xfs_da_hashname (fs/xfs/libxfs/xfs_da_btree.c) folds 4 bytes at a time: hash = b0 << 21 ^ b1 << 14 ^ b2 << 7 ^ b3 ^
// rol32(hash, 28). For 8 ASCII bytes, the 7-bit fields do not overlap, so the hash's top 4 bits are b3's low 4 bits and its
// low 28 bits are (b0..b3's 28 bits >> 4) XOR (b4..b7's 28 bits). The last four bytes follow from the first four; a name is
// kept when they all fall in the alphabet, which the hash's own 7-bit fields (0x60, 0x70, 0x70, 0x70) make likely: 0 there,
// and b4 would always be a control character. Each name is checked against the hash itself before it is linked.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static uint32_t rol32(uint32_t x, int n) { return x << n | x >> (32 - n); }

static uint32_t xfs_da_hashname(const unsigned char *name, int length) {
    uint32_t hash = 0;
    for (; length >= 4; length -= 4, name += 4)
        hash = (uint32_t)name[0] << 21 ^ (uint32_t)name[1] << 14 ^ (uint32_t)name[2] << 7 ^ name[3] ^ rol32(hash, 7 * 4);
    switch (length) {
    case 3: return (uint32_t)name[0] << 14 ^ (uint32_t)name[1] << 7 ^ name[2] ^ rol32(hash, 7 * 3);
    case 2: return (uint32_t)name[0] << 7 ^ name[1] ^ rol32(hash, 7 * 2);
    case 1: return name[0] ^ rol32(hash, 7 * 1);
    default: return hash;
    }
}

static const char alphabet[] = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

static int allowed(unsigned c) { return c != 0 && strchr(alphabet, (int)c) != NULL; }

static const char *targets;
static long target_count;

static void make(const char *dir, const char *name, long index) {
    char path[4096], target[4096];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    snprintf(target, sizeof target, "%s/t%ld", targets, index % target_count);
    if (link(target, path) != 0) {
        perror(path);
        exit(1);
    }
}

int main(int argc, char **argv) {
    if (argc != 6) {
        fprintf(stderr, "usage: xfs-names plain|collide DIR COUNT TARGETS N\n");
        return 64;
    }
    const char *dir = argv[2];
    long count = strtol(argv[3], NULL, 10), made = 0;
    targets = argv[4];
    target_count = strtol(argv[5], NULL, 10);
    if (target_count < 1) return 64;
    if (strcmp(argv[1], "plain") == 0) {
        char name[32];
        for (; made < count; made++) {
            snprintf(name, sizeof name, "n%ld", made);
            make(dir, name, made);
        }
        return 0;
    }
    if (strcmp(argv[1], "collide") != 0) return 64;
    const uint32_t wanted = 0x1C1C3870;
    const unsigned letters = sizeof alphabet - 1;
    for (unsigned i = 0; i < letters * letters * letters * letters && made < count; i++) {
        unsigned char name[9] = {
            (unsigned char)alphabet[i / (letters * letters * letters)],
            (unsigned char)alphabet[i / (letters * letters) % letters], (unsigned char)alphabet[i / letters % letters],
            (unsigned char)alphabet[i % letters]};
        if ((name[3] & 15u) != wanted >> 28) continue;
        uint32_t first = (uint32_t)name[0] << 21 | (uint32_t)name[1] << 14 | (uint32_t)name[2] << 7 | name[3];
        uint32_t second = (wanted & 0x0FFFFFFF) ^ first >> 4;
        for (int b = 0; b < 4; b++) name[4 + b] = (unsigned char)(second >> (21 - 7 * b) & 127);
        if (!allowed(name[4]) || !allowed(name[5]) || !allowed(name[6]) || !allowed(name[7])) continue;
        if (xfs_da_hashname(name, 8) != wanted) {
            fprintf(stderr, "xfs-names: %s hashes to %08x\n", (char *)name, xfs_da_hashname(name, 8));
            return 1;
        }
        make(dir, (const char *)name, made);
        made++;
    }
    if (made < count) {
        fprintf(stderr, "xfs-names: only %ld names of one hash\n", made);
        return 1;
    }
    return 0;
}
