#!/bin/sh
# Runs inside the container. See make-test-images.sh. The trees are built in the container's own /tmp:
# a directory shared with the host collects Finder's .DS_Store files while the script runs.
set -eu
# APK_MIRROR (macfs-tool images --mirror HOST): a host serving Alpine's repositories, when the CDN crawls.
[ -n "${APK_MIRROR:-}" ] && sed -i "s|dl-cdn.alpinelinux.org|$APK_MIRROR|" /etc/apk/repositories
apk add --no-cache btrfs-progs ntfs-3g ntfs-3g-progs e2fsprogs e2fsprogs-extra xfsprogs xfsprogs-extra util-linux attr zstd sgdisk coreutils findutils gcc musl-dev lzo-dev >/dev/null
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
# LZNT1 (roadmap 0014): the same tree, every file written compressed by ntfs-3g under a root marked compressed
# (FILE_ATTRIBUTE_COMPRESSED, 0x800, through system.ntfs_attrib_be): compressed units, units stored whole when they do not
# shrink (random.bin), sparse units, and a compressed file initialized short of its size.
rm -f ntfs-lznt1.img; truncate -s 64M ntfs-lznt1.img
mkntfs -Q -q -F -L ntfs-lznt1 ntfs-lznt1.img 2>/dev/null
ntfs-3g -o compression ntfs-lznt1.img /mnt/ntfs
setfattr -h -v 0x00000800 -n system.ntfs_attrib_be /mnt/ntfs
cp -a /tmp/tree/. /mnt/ntfs/
cp /tmp/initialized.bin /mnt/ntfs/big/initialized.bin && truncate -s 300000 /mnt/ntfs/big/initialized.bin
umount /mnt/ntfs
manifest /tmp/tree > ntfs-lznt1.manifest

# XFS (roadmap 0031): mkfs.xfs, then the tree copied in by the kernel's own driver. Beyond the tree: 10,000 names (hard links,
# no inodes needed) for a node-form directory; data islands for a data fork too large for the inode (a B+tree; 1,500 at 1 KiB
# blocks give it interior blocks); a symlink too long for the inode (a remote block); attributes, whose fork shrinks the data
# fork; and a preallocated file over freed random data (unwritten extents, whose stale bytes must read as zero). At the
# default 4 KiB blocks, and at 1 KiB with 8 KiB directory blocks. 300 MB is mkfs.xfs's minimum; the images stay sparse. The
# manifest is the mounted tree as the kernel shows it. (v4 volumes: this kernel does not mount them, so there is no reference.)
make_xfs() {  # $1 name, $2 islands, rest: mkfs.xfs options
    name=$1; islands=$2; shift 2
    rm -f "$name.img"; truncate -s 300M "$name.img"
    mkfs.xfs -q -f -L "$name" "$@" "$name.img"
    mount -t xfs -o loop "$name.img" /mnt/ref
    cp -a /tmp/tree/. /mnt/ref/
    # 40 names: past what the inode holds, within one directory block (block form).
    mkdir /mnt/ref/forty && for i in $(seq 1 40); do echo "$i" > "/mnt/ref/forty/name-$i"; done
    mkdir /mnt/ref/many && echo many > /mnt/ref/many/n0
    for i in $(seq 1 9999); do ln /mnt/ref/many/n0 /mnt/ref/many/n$i; done
    for i in $(seq 0 $((islands - 1))); do
        printf 'fragment %04d' "$i" | dd of=/mnt/ref/big/fragments.bin bs=1 seek=$((i * 65536)) conv=notrunc 2>/dev/null
    done
    fallocate -l 4194304 /mnt/ref/big/preallocated.bin
    printf 'middle' | dd of=/mnt/ref/big/preallocated.bin bs=1 seek=2097152 conv=notrunc 2>/dev/null
    for node in many big/fragments.bin dir hello.txt; do setfattr -n user.macfs -v "an attribute" "/mnt/ref/$node"; done
    # Random bytes written beneath the file system into the blocks of its unwritten extents: the stale data a reused disk
    # holds there, which must read as zero. The metadata stays as the kernel wrote it (xfs_repair finds nothing).
    umount /mnt/ref
    block=$(xfs_db -r -c "sb 0" -c "p blocksize" "$name.img" | awk '{ print $3 }')
    xfs_db -r -c "path /big/preallocated.bin" -c "p u3.bmx" "$name.img" | tr ' ' '\n' |
        sed -n 's/^[0-9]*:\[[0-9]*,\([0-9]*\),\([0-9]*\),1\]$/\1 \2/p' > /tmp/unwritten
    [ -s /tmp/unwritten ] || { echo "$name: no unwritten extent found" >&2; exit 1; }
    while read -r start count; do
        byte=$(xfs_db -r -c "convert fsblock $start byte" "$name.img" | sed 's/.*(\([0-9]*\)).*/\1/')
        head -c $((count * block)) /dev/urandom | dd of="$name.img" bs="$block" seek=$((byte / block)) conv=notrunc 2>/dev/null
    done < /tmp/unwritten
    xfs_repair -n "$name.img" >/dev/null 2>&1 || { echo "$name: xfs_repair -n finds damage" >&2; exit 1; }
    mount -t xfs -o loop "$name.img" /mnt/ref
    ln -s "/$(head -c 600 /dev/zero | tr '\0' 'x')/end" /mnt/ref/dir/long-link
    touch -m -d @1700000000.123456789 /mnt/ref/hello.txt
    manifest /mnt/ref > "$name.manifest"
    umount /mnt/ref
}
make_xfs xfs 100
make_xfs xfs-1k 1500 -b size=1024 -n size=8192

# XFS hashed lookup (roadmap 0037): each directory form the kernel makes, in images of their own, so the tree's manifests stay
# small. block/ (40 names in one directory block), leaf/ (data blocks indexed by one leaf block: 300 names at 4 KiB, 600 in
# 8 KiB directory blocks, where 300 still fit one block), collide/ (1,200 names of
# one hash, Scripts/xfs-names.c: a run of that hash across leaf blocks, which a lookup must follow), deep/ (250,000 names at
# 4 KiB: a node tree of two levels; 3,000 at 1 KiB with 8 KiB directory blocks, where two levels would take a million). Hard
# links to 1,000 files in targets/, so a lookup that finds the wrong entry finds the wrong inode. Every tenth name of leaf/,
# collide/ and deep/ is then removed: the kernel leaves stale leaf entries behind, which a lookup skips. The reference is the
# kernel's: every name left and the inode number it gives (.names).
gcc -O2 -o /tmp/xfs-names /scripts/xfs-names.c
make_xfs_hash() {  # $1 name, $2 names in leaf/, $3 in deep/, rest: mkfs.xfs options
    name=$1; leaf=$2; deep=$3; shift 3
    rm -f "$name.img"; truncate -s 300M "$name.img"
    mkfs.xfs -q -f -L "$name" "$@" "$name.img"
    mount -t xfs -o loop "$name.img" /mnt/ref
    mkdir /mnt/ref/targets /mnt/ref/block /mnt/ref/leaf /mnt/ref/collide /mnt/ref/deep
    i=0; while [ $i -lt 1000 ]; do echo $i > /mnt/ref/targets/t$i; i=$((i + 1)); done
    /tmp/xfs-names plain /mnt/ref/block 40 /mnt/ref/targets 1000
    /tmp/xfs-names plain /mnt/ref/leaf "$leaf" /mnt/ref/targets 1000
    /tmp/xfs-names collide /mnt/ref/collide 1200 /mnt/ref/targets 1000
    /tmp/xfs-names plain /mnt/ref/deep "$deep" /mnt/ref/targets 1000
    for d in leaf collide deep; do (cd /mnt/ref/$d && LC_ALL=C ls | awk 'NR % 10 == 0' | xargs rm --); done
    for d in block leaf deep; do for c in a b c d e f g h ... .a ..a; do : > "/mnt/ref/$d/$c"; done; done  # one-byte, dot-led
    (cd /mnt/ref && find . -mindepth 2 -maxdepth 2 -printf '%h\t%f\t%i\n' | sed 's|^\./||' | LC_ALL=C sort) > "$name.names"
    umount /mnt/ref
    xfs_repair -n "$name.img" >/dev/null 2>&1 || { echo "$name: xfs_repair -n finds damage" >&2; exit 1; }
}
make_xfs_hash xfs-hash 300 250000
make_xfs_hash xfs-hash-1k 600 3000 -b size=1024 -n size=8192

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
for name in xfs xfs-1k; do
    mount -t xfs -o loop,ro,norecovery "$name.img" /mnt/ref
    reference /mnt/ref "Linux $(uname -r) xfs" "type mode uid gid nlink size dirsize mtime ctime content" > "$name.reference"
    umount /mnt/ref
done
for name in ntfs ntfs-lznt1; do
    ntfs-3g -o ro "$name.img" /mnt/ref
    reference /mnt/ref "$(ntfs-3g --version 2>&1 | head -1)" "type nlink size dirsize mtime ctime content" > "$name.reference"
    umount /mnt/ref
done
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
# Directory hashes from xfsprogs (xfs_db's hash: xfs_da_hashname), the XFS hashed lookup's oracle (roadmap 0037), over the
# same names and names of 1 to 8 bytes 0xFF and 0x81: high bits where the fields of a byte group overlap, in every tail
# length. Lines: name in hex, hash.
cp /tmp/dxnames /tmp/xfsnames
for n in $(seq 1 8); do
    head -c "$n" /dev/zero | tr '\0' '\377' >> /tmp/xfsnames && echo >> /tmp/xfsnames
    head -c "$n" /dev/zero | tr '\0' '\201' >> /tmp/xfsnames && echo >> /tmp/xfsnames
done
: > xfshash.txt
while IFS= read -r name; do
    hex=$(printf '%s' "$name" | od -An -tx1 | tr -d ' \n')
    printf '%s\t%s\n' "$hex" "$(xfs_db -r -c "hash $name" xfs-hash.img)" >> xfshash.txt
done < /tmp/xfsnames
# zstd frames from the zstd CLI (the reference implementation) and their originals (roadmap 0013): levels 1 to 22 (22 with
# a long window), with and without a checksum and a content size, sizes around the 128 KiB block, and two frames back to back.
rm -rf zstd && mkdir zstd && mkdir -p /tmp/zin
seq 1 200000 > /tmp/zin/counting
head -c 300000 /dev/urandom > /tmp/zin/random
head -c 300000 /dev/zero > /tmp/zin/zeros
(seq 1 30000; head -c 100000 /dev/urandom; seq 1 30000) > /tmp/zin/mixed
cat /scripts/*.sh /scripts/*.c > /tmp/zin/scripts
for size in 0 1 2 3 4 5 100 131071 131072 131073 262145; do seq 1 100000 | head -c $size > /tmp/zin/size$size; done
for input in /tmp/zin/*; do
    name=$(basename "$input")
    for level in 1 3 9 19; do
        zstd -q -f -$level "$input" -o "zstd/$name-$level.zst" && cp "$input" "zstd/$name-$level.raw"
    done
    zstd -q -f --ultra -22 --long=27 "$input" -o "zstd/$name-22.zst" && cp "$input" "zstd/$name-22.raw"
    zstd -q -f -3 -C "$input" -o "zstd/$name-check.zst" && cp "$input" "zstd/$name-check.raw"
    zstd -q -c -3 --no-check < "$input" > "zstd/$name-nosize.zst" && cp "$input" "zstd/$name-nosize.raw"
done
cat zstd/counting-1.zst zstd/mixed-19.zst > zstd/two-frames.zst && cat /tmp/zin/counting /tmp/zin/mixed > zstd/two-frames.raw
rm -rf /tmp/zin
# LZO1X streams from liblzo2 (the reference implementation) and their originals: the decoder's oracle.
rm -rf lzo && mkdir lzo && gcc -O2 -o /tmp/lzo-fixtures /scripts/lzo-fixtures.c -llzo2 && /tmp/lzo-fixtures
mkfs.btrfs --version | head -1 > versions.txt
mkntfs --version 2>&1 | head -1 >> versions.txt
ntfs-3g --version 2>&1 | head -1 >> versions.txt
uname -r | sed "s/^/Linux /" >> versions.txt
apk info -v lzo 2>/dev/null | head -1 >> versions.txt
mke2fs -V 2>&1 | head -1 >> versions.txt
mkfs.xfs -V 2>&1 | head -1 >> versions.txt
