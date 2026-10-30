import FSCore
import Formats
import Testing

/// Block maps (roadmap 0018) against the readers themselves: every mappable file of every image, assembled from its map by
/// reading the device at the mapped offsets (zero where a piece is zero), equals the file as `read` returns it. Pieces are
/// ascending, contiguous, whole units, and stop at the file's last unit.
@Suite struct BlockMapTests {
    static let images = [
        "ext2", "ext3", "ext4", "ext4-inline", "ext4-bigalloc", "ext4-meta-bg", "ext4-grown", "ntfs", "ntfs-lznt1",
        "btrfs",
        "btrfs-zlib", "btrfs-lzo",
        "btrfs-xxhash",
        "btrfs-subvol"
    ]

    static func assembled(_ ranges: [MappedRange], source: any BlockSource) throws -> [UInt8] {
        var bytes: [UInt8] = []
        for range in ranges {
            if let physical = range.physical {
                bytes += try source.read(at: physical, count: Int(range.length))
            } else {
                bytes += [UInt8](repeating: 0, count: Int(range.length))
            }
        }
        return bytes
    }

    @Test(arguments: images)
    func everyMappableFileReadsFromItsMap(_ name: String) throws {
        let source = try ImageOracle.image(name)
        let format = try #require(DiskFormat.detect(source), "\(name): not detected")
        let fileSystem = try #require(
            try format.open(source) as? any BlockMapping, "\(name): the reader maps no blocks")
        var mappable = 0
        var unmappable: [String] = []
        try TreeWalk.visit(fileSystem) { (visit) throws(DiskError) in
            guard visit.entry.kind == .regular else { return }
            let id = visit.entry.id
            guard try fileSystem.isMappable(id) else {
                unmappable.append(visit.path)
                return
            }
            mappable += 1
            let size = try fileSystem.attributes(of: id).size
            let content = try fileSystem.read(id, at: 0, count: Int(size))
            let ranges = try fileSystem.blockMap(id, offset: 0, length: max(size, 1))
            var expected = ranges.first?.logical ?? 0
            for range in ranges {
                #expect(range.logical == expected, "\(name): \(visit.path): a gap or overlap at \(expected)")
                #expect(range.length > 0 && range.length % 512 == 0, "\(name): \(visit.path): length \(range.length)")
                #expect((range.physical ?? 0) % 512 == 0, "\(name): \(visit.path): physical \(range.physical ?? 0)")
                expected = range.logical + range.length
            }
            #expect(ranges.first?.logical == 0 || size == 0, "\(name): \(visit.path): the map does not start at 0")
            let bytes = try? Self.assembled(ranges, source: source)
            #expect(bytes.map { Array($0.prefix(Int(size))) } == content, "\(name): \(visit.path): mapped bytes differ")
            #expect((bytes?.count ?? 0) >= Int(size), "\(name): \(visit.path): the map ends before the file")
            // A range in the middle maps the units around it, nothing more.
            if size > 10_000 {
                let part = try fileSystem.blockMap(id, offset: 5_000, length: 3_000)
                let low = part.first?.logical ?? .max
                let high = part.last.map { $0.logical + $0.length } ?? 0
                #expect(
                    low <= 5_000 && high >= 8_000 && high - low <= 3_000 + 2 * 131_072,
                    "\(name): \(visit.path): \(low) to \(high)")
            }
        }
        // Small files are inline or resident in most formats; the large random file is stored as its bytes everywhere (even
        // where compression is on: it does not compress), so the map is exercised on every image. Not on NTFS with LZNT1: a
        // compressed stream stays compressed even in units stored whole, and the kernel must never be handed its clusters.
        if name == "ntfs-lznt1" {
            for path in ["big/random.bin", "big/counting.txt", "big/sparse.bin", "dir/medium.txt"] {
                #expect(unmappable.contains(path), "\(name): \(path) is compressed and must not be mapped")
            }
        } else {
            #expect(mappable >= 1 && !unmappable.contains("big/random.bin"), "\(name): \(mappable) mappable")
        }
    }

    /// What must not be mapped: inline, compressed and resident data stays with the reader.
    @Test(arguments: [
        ("ext4-inline", "hello.txt"), ("btrfs-zlib", "big/counting.txt"), ("btrfs-lzo", "big/counting.txt"),
        ("btrfs", "hello.txt"), ("ntfs", "hello.txt")
    ])
    func storedOtherwiseIsNotMapped(_ name: String, _ path: String) throws {
        let source = try ImageOracle.image(name)
        let fileSystem = try #require(try DiskFormat.detect(source)?.open(source) as? any BlockMapping)
        var id = fileSystem.rootID
        for part in path.split(separator: "/") { id = try fileSystem.lookup(Array(part.utf8), in: id).id }
        #expect(try fileSystem.isMappable(id) == false)
    }

    @Test func clippingFillsGapsAndStopsAtTheLastUnit() {
        let ranges = [
            MappedRange(logical: 0, length: 8192, physical: 100 * 4096),
            MappedRange(logical: 16384, length: 4096, physical: 200 * 4096)
        ]
        #expect(
            MappedRange.clip(ranges, offset: 5000, length: 15000, size: 18000, unit: 4096) == [
                MappedRange(logical: 4096, length: 4096, physical: 100 * 4096 + 4096),
                MappedRange(logical: 8192, length: 8192, physical: nil),
                MappedRange(logical: 16384, length: 4096, physical: 200 * 4096)
            ])
        #expect(MappedRange.clip(ranges, offset: 30000, length: 10, size: 18000, unit: 4096) == [])
        #expect(
            MappedRange.clip([], offset: 0, length: 10, size: 10, unit: 4096) == [
                MappedRange(logical: 0, length: 4096, physical: nil)
            ])
    }
}
