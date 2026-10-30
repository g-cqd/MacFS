#!/bin/sh
# Runs inside the container (macfs-tool images --corpus). The reference test suites' images, at the versions that build the
# test images (TestImages/versions.txt): e2fsprogs' tests/f_* (damaged ext images, each with e2fsck's expected exit status) and
# btrfs-progs' tests (raw images, and btrfs-image metadata dumps restored to raw). docs/conformance says how they are used.
set -eu
# APK_MIRROR (macfs-tool images --mirror HOST): a host serving Alpine's repositories, when the CDN crawls.
[ -n "${APK_MIRROR:-}" ] && sed -i "s|dl-cdn.alpinelinux.org|$APK_MIRROR|" /etc/apk/repositories
apk add --no-cache git btrfs-progs btrfs-progs-extra xz coreutils make gcc musl-dev zstd >/dev/null
cd /work
rm -rf e2fsprogs btrfs-progs zstd /tmp/src && mkdir -p e2fsprogs btrfs-progs zstd /tmp/src
git clone -q --depth 1 --branch v1.47.2 https://git.kernel.org/pub/scm/fs/ext2/e2fsprogs.git /tmp/src/e2fsprogs
git clone -q --depth 1 --branch v6.14 https://github.com/kdave/btrfs-progs.git /tmp/src/btrfs-progs

# index.tsv: image<TAB>e2fsck's verdict: "clean" when its expected output is only the passes and the summary (an exit status of
# 0 is not enough: checksum-only repairs exit 0), else "damaged".
for test in /tmp/src/e2fsprogs/tests/f_*; do
    [ -f "$test/image.gz" ] && [ -f "$test/expect.1" ] || continue
    name=$(basename "$test")
    gunzip -c "$test/image.gz" > /tmp/image && cp --sparse=always /tmp/image "e2fsprogs/$name.img" && rm /tmp/image
    if grep -q -v -E '^(Pass [0-9][A-Z]?: .*|test_filesys: [0-9]+/[0-9]+ files .*|Exit status is 0|)$' "$test/expect.1"; then
        verdict=damaged
    else
        verdict=clean
    fi
    printf '%s\t%s\n' "$name.img" "$verdict" >> e2fsprogs/index.tsv
done

# Every image file of the btrfs-progs suites, as a raw image: .xz unpacked, btrfs-image dumps restored.
find /tmp/src/btrfs-progs/tests -type f \( -name '*.img' -o -name '*.raw' -o -name '*.img.xz' -o -name '*.raw.xz' \) |
    LC_ALL=C sort | while read -r path; do
    rel=${path#/tmp/src/btrfs-progs/tests/}
    name=$(echo "$rel" | tr '/' '_' | sed 's/\.xz$//')
    case "$path" in *.xz) xz -dc "$path" > /tmp/unpacked ;; *) cp "$path" /tmp/unpacked ;; esac
    # Most are gigabytes of zeros: kept sparse, as the GPT test image is.
    if btrfs-image -r /tmp/unpacked /tmp/restored >/dev/null 2>&1; then
        cp --sparse=always /tmp/restored "btrfs-progs/$name"
        echo "$name	restored" >> btrfs-progs/index.tsv
    else
        cp --sparse=always /tmp/unpacked "btrfs-progs/$name"
        echo "$name	raw" >> btrfs-progs/index.tsv
    fi
    rm -f /tmp/unpacked /tmp/restored
done
printf 'e2fsprogs v1.47.2 tests/f_*: %s images\nbtrfs-progs v6.14 tests: %s images\n' \
    "$(wc -l < e2fsprogs/index.tsv)" "$(wc -l < btrfs-progs/index.tsv)" > versions.txt
rm -rf /tmp/src

# zstd's own decoder tests (roadmap 0013), at the version the bench compares with: the golden frames that must decode, those
# that must be refused, and 1,000 random valid frames from its decodecorpus generator (every block and table mode), each with
# its original.
git clone -q --depth 1 --branch v1.5.7 https://github.com/facebook/zstd.git /tmp/src/zstd
cp -r /tmp/src/zstd/tests/golden-decompression /tmp/src/zstd/tests/golden-decompression-errors zstd/
make -s -C /tmp/src/zstd/tests decodecorpus >/dev/null 2>&1
mkdir -p zstd/decodecorpus/frames zstd/decodecorpus/originals
/tmp/src/zstd/tests/decodecorpus -pzstd/decodecorpus/frames -ozstd/decodecorpus/originals -n1000 -s20261030 >/dev/null
# Damaged frames with the reference decoder's verdict: every error path of a decoder held to the reference's, not only to
# "no trap". The verdict is libzstd's one-shot ZSTD_decompress (built from the same v1.5.7 sources) into an 8 MiB buffer, as
# MacFS decodes into a flat buffer; the CLI's streaming decoder differs (it accepts a frame shorter than its declared size,
# and its memory limit refuses large windows). index.tsv: frame<TAB>"ok" (output beside it, .out) or "error".
make -s -C /tmp/src/zstd/lib libzstd.a >/dev/null 2>&1
gcc -O2 -I/tmp/src/zstd/lib -I/tmp/src/zstd/lib/common -o /tmp/zstd-verdict /scripts/zstd-verdict.c /tmp/src/zstd/lib/libzstd.a
gcc -O2 -o /tmp/zstd-damage /scripts/zstd-damage.c
mkdir -p zstd/damaged
(cd zstd && /tmp/zstd-damage $(ls decodecorpus/frames/*.zst | head -400))
/tmp/zstd-verdict zstd/damaged/*.zst > zstd/damaged/index.tsv
# Every single-bit flip of 40 decodecorpus frames of 100 to 600 bytes (large enough to hold Huffman and FSE tables), with the
# reference's verdict: the headers', tables' and streams' validation, exhaustively at those sizes.
mkdir -p zstd/flips
ls zstd/decodecorpus/frames/*.zst | while read -r f; do size=$(stat -c %s "$f"); [ "$size" -ge 100 ] && [ "$size" -le 600 ] && echo "$f"; done | head -40 > /tmp/small
/tmp/zstd-verdict --flips $(cat /tmp/small) > zstd/flips/index.tsv
# Sequences no CLI frame holds: more than 57 bits each, not the last of their block, some in table cells whose states start
# above 0 (the arm64 kernel's Lzs_wide path), encoded by the same libzstd (ZSTD_compressSequences), with their original.
mkdir -p zstd/wide
gcc -O2 -I/tmp/src/zstd/lib -o /tmp/zstd-wide /scripts/zstd-wide.c /tmp/src/zstd/lib/libzstd.a
/tmp/zstd-wide zstd/wide
