import FSCore
import Formats
import Foundation

// fsprobe <image-or-device> [--rounds N]
//
// Opens a volume with the reader its format needs, walks every directory and reads every file in 1 MiB pieces,
// and prints what it found and how long it took: the workload the kernels and readers are profiled on.

let arguments = Array(CommandLine.arguments.dropFirst())
guard let path = arguments.first else {
    print("usage: fsprobe <image-or-device> [--rounds N]")
    exit(64)
}
let rounds = arguments.firstIndex(of: "--rounds").flatMap { Int(arguments[$0 + 1]) } ?? 1

do {
    let source = try FileBlockSource(path: path)
    guard let format = DiskFormat.detect(source) else {
        print("\(path): no Btrfs, NTFS or ext volume")
        exit(1)
    }
    for round in 1 ... rounds {
        let start = DispatchTime.now().uptimeNanoseconds
        let fileSystem = try format.open(source)
        var nodes = 0
        var bytes: UInt64 = 0
        try TreeWalk.visit(fileSystem) { (visit) throws(DiskError) in
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
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        print(
            String(
                format: "round %d: %@ %@: %d nodes, %.1f MB in %.3f s (%.0f MB/s)", round, format.displayName,
                fileSystem.volume.label, nodes, Double(bytes) / 1e6, seconds, Double(bytes) / 1e6 / seconds))
    }
} catch {
    print("fsprobe: \(error)")
    exit(1)
}
