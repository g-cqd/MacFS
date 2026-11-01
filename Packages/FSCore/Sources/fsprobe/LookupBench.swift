import FSCore
import Formats
import Foundation

/// `fsprobe <image> --lookups <directory> [--rounds N] [--keep]`: looks up every name of one directory, as `stat` of each
/// path does, in a fixed shuffled order. Each round opens the volume afresh (unless `--keep`), so its first lookup meets
/// cold caches; the names come from a listing by another instance, which warms nothing the rounds use.
enum LookupBench {
    static func run(
        _ format: DiskFormat,
        _ source: any BlockSource,
        directory: String,
        rounds: Int,
        keep: Bool
    ) throws(DiskError) {
        var names = try Self.names(try format.open(source), directory)
        // SplitMix64 from a fixed seed: the same order every run.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in stride(from: names.count - 1, to: 0, by: -1) {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = (state ^ (state >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            names.swapAt(index, Int((mixed ^ (mixed >> 31)) % UInt64(index + 1)))
        }
        let kept = keep ? try format.open(source) : nil
        for round in 1 ... rounds {
            let fileSystem: any ReadOnlyFileSystem
            if let kept { fileSystem = kept } else { fileSystem = try format.open(source) }
            let parent = try Self.resolve(fileSystem, directory)
            let began = DispatchTime.now().uptimeNanoseconds
            _ = try fileSystem.lookup(names[0], in: parent)
            let first = DispatchTime.now().uptimeNanoseconds
            for name in names.dropFirst() { _ = try fileSystem.lookup(name, in: parent) }
            let end = DispatchTime.now().uptimeNanoseconds
            print(
                String(
                    format: "round %d: %@ %@: %d lookups in %.3f s (%.0f lookups/s), the first %.1f µs",
                    round,
                    format.displayName,
                    directory,
                    names.count,
                    Double(end - began) / 1e9,
                    Double(names.count) / (Double(end - began) / 1e9),
                    Double(first - began) / 1e3
                )
            )
        }
    }

    private static func resolve(_ fileSystem: any ReadOnlyFileSystem, _ path: String) throws(DiskError) -> UInt64 {
        var id = fileSystem.rootID
        for part in path.split(separator: "/") { id = try fileSystem.lookup(Array(part.utf8), in: id).id }
        return id
    }

    private static func names(_ fileSystem: any ReadOnlyFileSystem, _ path: String) throws(DiskError) -> [[UInt8]] {
        let directory = try resolve(fileSystem, path)
        var names: [[UInt8]] = []
        var cookie: UInt64 = 0
        while true {
            let page = try fileSystem.entries(of: directory, from: cookie, limit: 4096)
            names += page.map(\.name)
            guard let last = page.last, page.count == 4096 else { break }
            cookie = last.nextCookie
        }
        guard !names.isEmpty else { throw .notFound }
        return names
    }
}
