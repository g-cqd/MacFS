#!/bin/sh
# Runs inside the container (macfs-tool images --corpus). The reference test suites' images, at the versions that build the
# test images (TestImages/versions.txt): e2fsprogs' tests/f_* (damaged ext images, each with e2fsck's expected exit status) and
# btrfs-progs' tests (raw images, and btrfs-image metadata dumps restored to raw). docs/conformance says how they are used.
set -eu
apk add --no-cache git btrfs-progs btrfs-progs-extra xz coreutils >/dev/null
cd /work
rm -rf e2fsprogs btrfs-progs /tmp/src && mkdir -p e2fsprogs btrfs-progs /tmp/src
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
