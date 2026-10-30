#!/bin/sh
# Runs inside the container. See make-test-images.sh. The trees are built in the container's own /tmp:
# a directory shared with the host collects Finder's .DS_Store files while the script runs.
set -eu
apk add --no-cache btrfs-progs ntfs-3g ntfs-3g-progs e2fsprogs e2fsprogs-extra sgdisk coreutils findutils gcc musl-dev lzo-dev >/dev/null
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
# Twelve data islands between holes: more extents than the four an ext4 inode holds, so its extent tree gets an external block
# and that block's checksum tail (roadmap 0015).
for i in $(seq 0 11); do
    printf 'island %02d' "$i" | dd of=/tmp/tree/big/islands.bin bs=1 seek=$((i * 65536)) conv=notrunc 2>/dev/null
done
for i in $(seq 1 300); do echo "file $i" > /tmp/tree/dir/sub/f$i.txt; done
# Non-ASCII names in an htree directory: there the signed and unsigned directory hashes differ (roadmap 0016).
for i in $(seq 1 20); do echo "accent $i" > "/tmp/tree/dir/sub/é$i.txt"; done
echo inside > "/tmp/tree/spaces and ünïcödé/naïve.txt"
echo subvolume > /tmp/tree/vol/in-subvolume.txt
ln -s ../hello.txt /tmp/tree/dir/link
# A second name for one file: link counts are part of conformance (the reference manifests carry them).
ln /tmp/tree/dir/medium.txt /tmp/tree/big/medium-again.txt
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
# mke2fs -d stores whole seconds. The Linux kernel then writes nanosecond times (and so its own inode checksums) into a file,
# a directory and a symlink, so the readers' time decoding meets the kernel's encoding (docs/conformance/ext.md).
mkdir -p /mnt/ref
kernel_touch() {  # $1 image, $2 byte offset of the file system
    mount -t ext4 -o loop,offset="$2" "$1" /mnt/ref
    touch -m -d @1700000000.123456789 /mnt/ref/hello.txt
    touch -m -d @1600000000.987654321 /mnt/ref/dir
    touch -h -m -d @1500000000.000000001 /mnt/ref/dir/link
    umount /mnt/ref
}

make_ext() {  # $1 name, $2 size, rest: mke2fs options; HASH= a directory hash, SIGNED=1 the signed variant
    name=$1; size=$2; shift 2
    rm -f "$name.img"
    mke2fs -q -F -L "$name" -d /tmp/tree "$@" "$name.img" "$size"
    if [ -n "${HASH:-}" ]; then tune2fs -E hash_alg="$HASH" "$name.img" >/dev/null; fi
    if [ -n "${SIGNED:-}" ]; then debugfs -w -R "ssv flags 1" "$name.img" >/dev/null 2>&1; fi
    # mke2fs -d writes linear directories; e2fsck -D rebuilds them as htrees where dir_index is on.
    # Exit 1 means "file system modified", which is the point.
    e2fsck -f -y -D "$name.img" >/dev/null 2>&1 || [ $? -eq 1 ]
    kernel_touch "$name.img" 0
    manifest /tmp/tree > "$name.manifest"
}
make_ext ext2 64M -t ext2 -b 1024
# Directory hashes (roadmap 0016): half-MD4 is the default; ext3 hashes with TEA, ext4-uuid-seed with the legacy hash, and
# ext4-bigalloc signed (the flag set and the htrees rebuilt by e2fsck; an arm64 container defaults to unsigned).
HASH=tea make_ext ext3 64M -t ext3
make_ext ext4 128M -t ext4
make_ext ext4-inline 128M -t ext4 -O inline_data
SIGNED=1 make_ext ext4-bigalloc 128M -t ext4 -b 4096 -O bigalloc -C 16384
# Every other ext4 image stores its checksum seed (csum_seed); this one derives it from the UUID, the other path (0015).
HASH=legacy make_ext ext4-uuid-seed 128M -t ext4 -O ^metadata_csum_seed
# meta_bg (roadmap 0016): each metagroup's descriptors in the first block of its first group (backups in its second and last),
# not one table after the superblock. 1 KiB blocks, 1024 per group: 64 groups, 16 descriptors per block, 4 metagroups; eight
# inodes per group spread the tree's inodes over three of them. Without sparse_super every group has a superblock backup, so
# each metagroup's descriptors sit one block in, after it.
make_ext ext4-meta-bg 64M -t ext4 -b 1024 -g 1024 -N 512 -O meta_bg,^resize_inode,^sparse_super
# What the kernel makes of a mounted volume with no reserved descriptor blocks that outgrows its table: meta_bg from
# s_first_meta_bg on, the old table before it (offline, resize2fs moves blocks instead). Filled by the kernel after growing:
# its allocator spreads directories into the new groups, and it turns dir/sub into an htree itself.
rm -f ext4-grown.img
mke2fs -q -F -L ext4-grown -t ext4 -b 1024 -g 1024 -N 1024 -O ^resize_inode ext4-grown.img 16M
truncate -s 64M ext4-grown.img
loop=$(losetup -f) && losetup "$loop" ext4-grown.img && mount -t ext4 "$loop" /mnt/ref
resize2fs "$loop" >/dev/null
cp -a /tmp/tree/. /mnt/ref/
# 10,000 names, hard links to one file (no inodes needed): more leaves than one 1 KiB root indexes, so the kernel gives the
# htree a second level of interior nodes (roadmap 0016). The manifest is the mounted tree as the kernel shows it.
mkdir /mnt/ref/many && echo many > /mnt/ref/many/n0
for i in $(seq 1 9999); do ln /mnt/ref/many/n0 /mnt/ref/many/n$i; done
manifest /mnt/ref | grep -v '^lost+found' > ext4-grown.manifest
umount /mnt/ref && losetup -d "$loop"
kernel_touch ext4-grown.img 0
# A partitioned disk: one GPT partition of type "Linux filesystem" at 1 MiB, so Disk Arbitration matches the
# module by partition type (FSMediaTypes), not as a partitionless whole disk.
# mke2fs zeroes the start of the file even with an offset, so the partition table is written after it; the file
# system ends at 121 MiB, clear of the backup GPT in the last 17 KiB. Built in /tmp, then copied sparse.
rm -f ext4-gpt.img /tmp/ext4-gpt.img; truncate -s 128M /tmp/ext4-gpt.img
mke2fs -q -F -L ext4-gpt -t ext4 -d /tmp/tree -E offset=1048576 /tmp/ext4-gpt.img 120M
# Not -q: with it this sgdisk exits 0 and writes no table.
sgdisk -o -n 1:2048:0 -t 1:8300 /tmp/ext4-gpt.img >/dev/null
kernel_touch /tmp/ext4-gpt.img 1048576
cp --sparse=always /tmp/ext4-gpt.img ext4-gpt.img && rm /tmp/ext4-gpt.img
manifest /tmp/tree > ext4-gpt.manifest

# NTFS: mkntfs, then ntfs-3g (the reference driver, through FUSE: the container runs with --cap-add ALL) copies the whole tree.
[ -e /dev/fuse ] || mknod /dev/fuse c 10 229
# Filled with 0xAA before a quick format, which leaves free clusters as they were: a reader (or a block map) that shows bytes
# past a stream's initialized size shows 0xAA, not the zeros ntfs-3g reads.
rm -f ntfs.img; head -c 67108864 /dev/zero | tr '\0' '\252' > ntfs.img
mkntfs -Q -q -F -L ntfs ntfs.img 2>/dev/null
# Plus a file extended past its data on the mount itself: ntfs-3g then leaves the stream's initialized size at the data, and
# the rest must read as zero (a block map may not map past it, roadmap 0018). Only here: mke2fs -d with inline_data drops such
# a file's trailing hole (docs/conformance/ext.md).
head -c 100000 /dev/urandom > /tmp/initialized.bin
mkdir -p /mnt/ntfs && ntfs-3g ntfs.img /mnt/ntfs && cp -a /tmp/tree/. /mnt/ntfs/
cp /tmp/initialized.bin /mnt/ntfs/big/initialized.bin && truncate -s 300000 /mnt/ntfs/big/initialized.bin
umount /mnt/ntfs
# What Windows leaves after a preallocation: stale bytes in the last data cluster past the initialized size. Written over the
# cluster's tail (ntfs-3g zero-pads it), so only a reader that honours the initialized size reads zeros there.
lcn=$(ntfsinfo -v -F /big/initialized.bin ntfs.img 2>/dev/null | awk '$1 == "0x0" { print $2; exit }')
cluster=$(ntfsinfo -m ntfs.img 2>/dev/null | awk -F: '/Cluster Size/ { gsub(/ /, "", $2); print $2; exit }')
head -c 2400 /dev/zero | tr '\0' '\252' | dd of=ntfs.img bs=1 seek=$((lcn * cluster + 100000)) conv=notrunc 2>/dev/null
cp /tmp/initialized.bin /tmp/tree/big/initialized.bin && truncate -s 300000 /tmp/tree/big/initialized.bin
manifest /tmp/tree > ntfs.manifest

# Reference manifests: each image as its reference implementation presents it (docs/conformance). The Linux kernel mounts ext,
# ntfs-3g mounts NTFS, and btrfs-progs' own reader restores Btrfs (this kernel has no Btrfs driver). The fields line names what
# that implementation owns: ntfs-3g synthesizes modes and owners, and a restore makes fresh link counts.
reference() {  # $1 root, $2 tool, $3 fields
    printf '# reference: %s\n# fields: %s\n' "$2" "$3"
    (cd "$1" && find . -mindepth 1 -printf '%P\t%y\t%m\t%U\t%G\t%n\t%s\t%T@\t%C@\t' \
        -exec sh -c 'if [ -L "$1" ]; then readlink "$1"; elif [ -f "$1" ]; then sha256sum < "$1" | cut -d" " -f1; else echo -; fi' _ {} \; \
        | LC_ALL=C sort)
}
for name in ext2 ext3 ext4 ext4-inline ext4-bigalloc ext4-uuid-seed ext4-meta-bg ext4-grown ext4-gpt; do
    offset=0; [ "$name" = ext4-gpt ] && offset=1048576
    mount -t ext4 -o loop,ro,noload,offset=$offset "$name.img" /mnt/ref
    reference /mnt/ref "Linux $(uname -r) ext4" "type mode uid gid nlink size dirsize mtime ctime content" > "$name.reference"
    umount /mnt/ref
done
ntfs-3g -o ro ntfs.img /mnt/ref
reference /mnt/ref "$(ntfs-3g --version 2>&1 | head -1)" "type nlink size dirsize mtime ctime content" > ntfs.reference
umount /mnt/ref
for name in btrfs btrfs-zlib btrfs-lzo btrfs-zstd btrfs-xxhash btrfs-subvol; do
    rm -rf /tmp/restored && mkdir /tmp/restored
    btrfs restore -m -S -x "$name.img" /tmp/restored >/dev/null 2>&1
    reference /tmp/restored "$(btrfs --version | head -1) restore" "type mode uid gid size mtime content" > "$name.reference"
done
rm -rf /tmp/restored
rm -rf /tmp/tree
# Directory hashes from e2fsprogs (debugfs dx_hash), the htree lookup's oracle (roadmap 0016): versions 0 to 5 (legacy,
# half-MD4, TEA, then the same unsigned), names of 1 to 70 bytes (across the 16- and 32-byte blocks the hashes take in turn),
# non-ASCII names (where signedness shows) and two seeds. Lines: version, seed, name in hex, hash, minor hash.
phrase=Thequickbrownfox-jumps_over.the~lazy+dog=0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefgh
: > /tmp/dxnames
for n in $(seq 1 70); do printf '%s\n' "$phrase" | cut -c1-"$n" >> /tmp/dxnames; done
printf '%s\n' é naïve.txt ünïcödé-ÿ 日本語のファイル名.txt "$(printf '\377\200abc')" >> /tmp/dxnames
: > dxhash.txt
for seed in 00000000-0000-0000-0000-000000000000 01020304-0506-0708-090a-0b0c0d0e0f10; do
    for version in 0 1 2 3 4 5; do
        while IFS= read -r name; do
            out=$(debugfs -R "dx_hash -h $version -s $seed $name" ext4.img 2>/dev/null | tail -1)
            hex=$(printf '%s' "$name" | od -An -tx1 | tr -d ' \n')
            # From the end of the line: the name may hold anything (sed's . does not match invalid UTF-8).
            hashes=$(echo "$out" | awk '{ print $(NF - 2), $NF }' | tr -d ')')
            printf '%s\t%s\t%s\t%s\n' "$version" "$seed" "$hex" "$hashes" | tr ' ' '\t' >> dxhash.txt
        done < /tmp/dxnames
    done
done
# LZO1X streams from liblzo2 (the reference implementation) and their originals: the decoder's oracle.
rm -rf lzo && mkdir lzo && gcc -O2 -o /tmp/lzo-fixtures /scripts/lzo-fixtures.c -llzo2 && /tmp/lzo-fixtures
mkfs.btrfs --version | head -1 > versions.txt
mkntfs --version 2>&1 | head -1 >> versions.txt
ntfs-3g --version 2>&1 | head -1 >> versions.txt
uname -r | sed "s/^/Linux /" >> versions.txt
apk info -v lzo 2>/dev/null | head -1 >> versions.txt
mke2fs -V 2>&1 | head -1 >> versions.txt
