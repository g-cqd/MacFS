import FSCore
import Formats
import Foundation

// fsprobe <image-or-device> [--rounds N] [--under PATH]
// fsprobe --tree <directory> [--rounds N]
//
// Opens a volume with the reader its format needs, walks every directory and reads every file in 1 MiB pieces,
// and prints what it found and how long it took: the workload the kernels and readers are profiled on. With --tree, the same
// workload on a directory of the host's own file system: the baseline (docs/conformance/performance.md).

let arguments = Array(CommandLine.arguments.dropFirst())
guard let path = arguments.first else {
    print("usage: fsprobe <image-or-device> [--rounds N]")
    exit(64)
}
let rounds = arguments.firstIndex(of: "--rounds").flatMap { Int(arguments[$0 + 1]) } ?? 1
// Walk only below this path of the volume: one category of the bench tree at a time (large files, or small ones).
let under = arguments.firstIndex(of: "--under").map { arguments[$0 + 1] }

if path == "--tree", arguments.count > 1 {
    for round in 1 ... rounds {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = NativeWalk.walk(arguments[1])
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        print(
            String(
                format: "round %d: native %@: %d nodes, %.1f MB in %.3f s (%.0f MB/s, %.0f nodes/s)", round,
                arguments[1],
                result.nodes, Double(result.bytes) / 1e6, seconds, Double(result.bytes) / 1e6 / seconds,
                Double(result.nodes) / seconds))
    }
    exit(0)
}

do {
    let source = try FileBlockSource(path: path)
    guard let format = DiskFormat.detect(source) else {
        print("\(path): no Btrfs, NTFS or ext volume")
        exit(1)
    }
    for round in 1 ... rounds {
        let began = DispatchTime.now().uptimeNanoseconds
        let fileSystem = try format.open(source)
        var nodes = 0
        var bytes: UInt64 = 0
        var start = fileSystem.rootID
        for part in (under ?? "").split(separator: "/") {
            start = try fileSystem.lookup(Array(part.utf8), in: start).id
        }
        try TreeWalk.visit(fileSystem, from: start) { (visit) throws(DiskError) in
            nodes += 1
            guard visit.entry.kind == .regular else { return }
            var offset: UInt64 = 0
            while true {
                let piece = try fileSystem.read(visit.entry.id, at: offset, count: 1 << 20)
                if piece.isEmpty { break }
                bytes += UInt64(piece.count)
                offset += UInt64(piece.count)
            }
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9
        print(
            String(
                format: "round %d: %@ %@: %d nodes, %.1f MB in %.3f s (%.0f MB/s, %.0f nodes/s)", round,
                format.displayName, fileSystem.volume.label, nodes, Double(bytes) / 1e6, seconds,
                Double(bytes) / 1e6 / seconds, Double(nodes) / seconds))
    }
} catch {
    print("fsprobe: \(error)")
    exit(1)
}
