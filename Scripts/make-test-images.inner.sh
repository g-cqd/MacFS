#!/bin/sh
# Runs inside the container. See make-test-images.sh. The trees are built in the container's own /tmp:
# a directory shared with the host collects Finder's .DS_Store files while the script runs.
set -eu
apk add --no-cache btrfs-progs ntfs-3g-progs e2fsprogs sgdisk coreutils findutils >/dev/null
cd /work
rm -rf /tmp/tree && mkdir -p /tmp/tree/dir/sub /tmp/tree/big /tmp/tree/vol "/tmp/tree/spaces and ünïcödé"
printf 'hello btrfs\n' > /tmp/tree/hello.txt
head -c 5000 /dev/zero | tr '\0' 'x' > /tmp/tree/dir/medium.txt
# Longer than i_block's 60 bytes and short enough to stay inline: the rest goes to system.data.
seq 1 30 | head -c 100 > /tmp/tree/dir/hundred.txt
# Compressible, larger than one 128 KiB compressed extent, with a pattern that catches misplaced bytes.
seq 1 200000 > /tmp/tree/big/counting.txt
head -c 3072000 /dev/urandom > /tmp/tree/big/random.bin
truncate -s 1M /tmp/tree/big/sparse.bin && printf 'tail' >> /tmp/tree/big/sparse.bin
for i in $(seq 1 300); do echo "file $i" > /tmp/tree/dir/sub/f$i.txt; done
echo inside > "/tmp/tree/spaces and ünïcödé/naïve.txt"
echo subvolume > /tmp/tree/vol/in-subvolume.txt
ln -s ../hello.txt /tmp/tree/dir/link
ln -s /absolute/target /tmp/tree/dir/absolute-link

manifest() {  # $1 = root directory; prints path<TAB>type<TAB>size<TAB>sha256-or-target
    (cd "$1" && find . -mindepth 1 | LC_ALL=C sort | while read -r p; do
        rel=${p#./}
        if [ -L "$p" ]; then printf '%s\tlink\t0\t%s\n' "$rel" "$(readlink "$p")"
        elif [ -d "$p" ]; then printf '%s\tdir\t0\t-\n' "$rel"
        else printf '%s\tfile\t%s\t%s\n' "$rel" "$(stat -c %s "$p")" "$(sha256sum "$p" | cut -d' ' -f1)"; fi
    done)
}

make_btrfs() {  # $1 name, rest: mkfs options
    name=$1; shift
    rm -f "$name.img"; truncate -s 256M "$name.img"
    mkfs.btrfs -q -L "$name" --rootdir /tmp/tree "$@" "$name.img"
    manifest /tmp/tree > "$name.manifest"
}
make_btrfs btrfs
make_btrfs btrfs-zlib --compress zlib
make_btrfs btrfs-lzo --compress lzo
make_btrfs btrfs-zstd --compress zstd
make_btrfs btrfs-xxhash --csum xxhash
make_btrfs btrfs-subvol --subvol vol

# ext2/3/4 via mke2fs -d: indirect blocks with 1 KiB blocks (ext2), a journal (ext3), extents, htree
# directories, 64-bit and metadata checksums (ext4 defaults), and inline data.
make_ext() {  # $1 name, $2 size, rest: mke2fs options
    name=$1; size=$2; shift 2
    rm -f "$name.img"
    mke2fs -q -F -L "$name" -d /tmp/tree "$@" "$name.img" "$size"
    # mke2fs -d writes linear directories; e2fsck -D rebuilds them as htrees where dir_index is on.
    # Exit 1 means "file system modified", which is the point.
    e2fsck -f -y -D "$name.img" >/dev/null 2>&1 || [ $? -eq 1 ]
    manifest /tmp/tree > "$name.manifest"
}
make_ext ext2 64M -t ext2 -b 1024
make_ext ext3 64M -t ext3
make_ext ext4 128M -t ext4
make_ext ext4-inline 128M -t ext4 -O inline_data
make_ext ext4-bigalloc 128M -t ext4 -b 4096 -O bigalloc -C 16384
# A partitioned disk: one GPT partition of type "Linux filesystem" at 1 MiB, so Disk Arbitration matches the
# module by partition type (FSMediaTypes), not as a partitionless whole disk.
# mke2fs zeroes the start of the file even with an offset, so the partition table is written after it; the file
# system ends at 121 MiB, clear of the backup GPT in the last 17 KiB. Built in /tmp, then copied sparse.
rm -f ext4-gpt.img /tmp/ext4-gpt.img; truncate -s 128M /tmp/ext4-gpt.img
mke2fs -q -F -L ext4-gpt -t ext4 -d /tmp/tree -E offset=1048576 /tmp/ext4-gpt.img 120M
# Not -q: with it this sgdisk exits 0 and writes no table.
sgdisk -o -n 1:2048:0 -t 1:8300 /tmp/ext4-gpt.img >/dev/null
cp --sparse=always /tmp/ext4-gpt.img ext4-gpt.img && rm /tmp/ext4-gpt.img
manifest /tmp/tree > ext4-gpt.manifest

# NTFS: ntfscp writes files into an unmounted image (no FUSE in a container), so the /tmp/tree is flat.
rm -rf /tmp/ntree && mkdir /tmp/ntree
cp /tmp/tree/hello.txt /tmp/tree/dir/medium.txt /tmp/tree/big/counting.txt /tmp/tree/big/random.bin /tmp/ntree/
for i in $(seq 1 300); do cp /tmp/tree/dir/sub/f$i.txt /tmp/ntree/; done
cp "/tmp/tree/spaces and ünïcödé/naïve.txt" /tmp/ntree/
rm -f ntfs.img; truncate -s 64M ntfs.img
mkntfs -Q -q -F -L ntfs ntfs.img 2>/dev/null
for f in /tmp/ntree/*; do ntfscp ntfs.img "$f" "$(basename "$f")" >/dev/null; done
manifest /tmp/ntree > ntfs.manifest
rm -rf /tmp/tree /tmp/ntree
mkfs.btrfs --version | head -1 > versions.txt
mkntfs --version 2>&1 | head -1 >> versions.txt
mke2fs -V 2>&1 | head -1 >> versions.txt
