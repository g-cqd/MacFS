#!/bin/sh
# Runs inside the container (swift package images --bench): the profiling corpus for roadmap 0012, about 600 MB of
# data in 1 GiB images. Not used by the tests; built in the container's own /tmp like the test trees.
set -eu
apk add --no-cache btrfs-progs e2fsprogs ntfs-3g ntfs-3g-progs attr coreutils findutils >/dev/null
cd /work
rm -rf /tmp/bench && mkdir -p /tmp/bench/text /tmp/bench/random /tmp/bench/small
# Compressible: 200 MB of numbered lines. Incompressible: 200 MB of random bytes. Metadata: 20,000 files in 100 directories.
for i in $(seq 1 20); do seq $((i * 1000000)) $((i * 1000000 + 1300000)) > /tmp/bench/text/t$i.txt; done
for i in $(seq 1 10); do head -c 20000000 /dev/urandom > /tmp/bench/random/r$i.bin; done
for d in $(seq 1 100); do mkdir /tmp/bench/small/d$d; for f in $(seq 1 200); do echo "$d $f" > /tmp/bench/small/d$d/f$f; done; done
for variant in plain zlib lzo zstd; do
    rm -f btrfs-$variant.img; truncate -s 1G btrfs-$variant.img
    case $variant in
        plain) mkfs.btrfs -q -L bench --rootdir /tmp/bench btrfs-$variant.img ;;
        *) mkfs.btrfs -q -L bench --rootdir /tmp/bench --compress $variant btrfs-$variant.img ;;
    esac
done
rm -f ext4.img; mke2fs -q -F -L bench -t ext4 -d /tmp/bench ext4.img 1G
# NTFS through ntfs-3g (FUSE; the container runs with --cap-add ALL).
[ -e /dev/fuse ] || mknod /dev/fuse c 10 229
rm -f ntfs.img; truncate -s 1G ntfs.img; mkntfs -Q -q -F -L bench ntfs.img 2>/dev/null
mkdir -p /mnt/ntfs && ntfs-3g ntfs.img /mnt/ntfs && cp -a /tmp/bench/. /mnt/ntfs/ && umount /mnt/ntfs
# The same tree LZNT1-compressed (roadmap 0014): every file written under a root marked compressed.
rm -f ntfs-lznt1.img; truncate -s 1G ntfs-lznt1.img; mkntfs -Q -q -F -L bench ntfs-lznt1.img 2>/dev/null
ntfs-3g -o compression ntfs-lznt1.img /mnt/ntfs && setfattr -h -v 0x00000800 -n system.ntfs_attrib_be /mnt/ntfs
cp -a /tmp/bench/. /mnt/ntfs/ && umount /mnt/ntfs
# The same tree on the host's own file system: the baseline the readers are measured against (`fsprobe --tree`).
# Copied beside the old tree, then swapped in: Finder writes .DS_Store files into a shared directory while it is deleted, so
# an rm -rf of the old tree can fail, and inside an && list set -e would not stop on it.
rm -rf tree.new; cp -a /tmp/bench tree.new
if [ -d tree ]; then mv tree tree.old; fi
mv tree.new tree
rm -rf tree.old || echo "tree.old: left behind (Finder files)" >&2
test "$(find tree -type f ! -name .DS_Store | wc -l)" -eq 20030
rm -rf /tmp/bench
