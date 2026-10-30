import FSCore
import MountKit

/// NFS file handles: "MFS3", four bytes of the volume's identifier, then the mount identifier.
/// A handle from another volume, or one this server could never have issued, is refused (BADHANDLE).
struct FileHandles: Sendable {
    private let prefix: [UInt8]

    init(volume: VolumeDescription) {
        prefix = Array("MFS3".utf8) + (volume.uuid + [0, 0, 0, 0]).prefix(4)
    }

    func handle(_ mountID: UInt64) -> [UInt8] {
        var writer = XDRWriter()
        writer.u64(mountID)
        return prefix + writer.bytes
    }

    func mountID(_ handle: [UInt8]) -> UInt64? {
        guard handle.count == 16, handle.prefix(8).elementsEqual(prefix) else { return nil }
        var reader = XDRReader(Array(handle.suffix(8)))
        guard let id = try? reader.u64(), id >= MountedTree.root else { return nil }
        return id
    }
}
