#!/bin/sh
# Runs inside the container (swift package images --bench): the profiling corpus for roadmap 0012, about 600 MB of
# data in 1 GiB images. Not used by the tests; built in the container's own /tmp like the test trees.
set -eu
apk add --no-cache btrfs-progs e2fsprogs coreutils findutils >/dev/null
cd /work
rm -rf /tmp/bench && mkdir -p /tmp/bench/text /tmp/bench/random /tmp/bench/small
# Compressible: 200 MB of numbered lines. Incompressible: 200 MB of random bytes. Metadata: 20,000 files in 100 directories.
for i in $(seq 1 20); do seq $((i * 1000000)) $((i * 1000000 + 1300000)) > /tmp/bench/text/t$i.txt; done
for i in $(seq 1 10); do head -c 20000000 /dev/urandom > /tmp/bench/random/r$i.bin; done
for d in $(seq 1 100); do mkdir /tmp/bench/small/d$d; for f in $(seq 1 200); do echo "$d $f" > /tmp/bench/small/d$d/f$f; done; done
for variant in plain zlib lzo; do
    rm -f btrfs-$variant.img; truncate -s 1G btrfs-$variant.img
    case $variant in
        plain) mkfs.btrfs -q -L bench --rootdir /tmp/bench btrfs-$variant.img ;;
        *) mkfs.btrfs -q -L bench --rootdir /tmp/bench --compress $variant btrfs-$variant.img ;;
    esac
done
rm -f ext4.img; mke2fs -q -F -L bench -t ext4 -d /tmp/bench ext4.img 1G
rm -rf /tmp/bench
