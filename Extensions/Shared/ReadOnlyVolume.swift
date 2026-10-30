import FSCore
import FSKit
import MountKit
import Synchronization
import os

/// A mounted read-only volume over ``MountedTree`` (the macOS 27 `FSVolume.Handler` interface).
///
/// Every mutating operation answers `EROFS`. Items are kept per mount identifier until FSKit reclaims
/// them, so the same node is always the same `FSItem`.
final class ReadOnlyVolume: FSVolume, @unchecked Sendable {
    let tree: MountedTree
    let shortName: String
    let log: Logger
    /// The device the volume lives on: block maps name it for the kernel's own reads (roadmap 0018).
    let device: FSBlockDeviceResource
    private let items = Mutex<[UInt64: ReadOnlyItem]>([:])

    init(tree: MountedTree, shortName: String, log: Logger, device: FSBlockDeviceResource) {
        self.tree = tree
        self.shortName = shortName
        self.log = log
        self.device = device
        let description = tree.fileSystem.volume
        let identifier = FSVolume.Identifier(uuid: description.foundationUUID)
        super
            .init(
                volumeID: identifier,
                volumeName: FSFileName(string: description.label.isEmpty ? shortName : description.label))
    }

    func item(_ mountID: UInt64) -> ReadOnlyItem {
        items.withLock { items in
            if let existing = items[mountID] { return existing }
            let made = ReadOnlyItem(mountID: mountID)
            items[mountID] = made
            return made
        }
    }

    func forget(_ item: FSItem) {
        guard let item = item as? ReadOnlyItem else { return }
        _ = items.withLock { $0.removeValue(forKey: item.mountID) }
    }

    /// The reader's attributes as FSKit attributes, with mount identifiers.
    func attributes(_ mountID: UInt64) throws(DiskError) -> FSItem.Attributes {
        let node = try tree.fileSystem.attributes(of: tree.readerID(for: mountID))
        let attributes = FSItem.Attributes()
        attributes.type = Self.type(node.kind)
        attributes.mode = UInt32(Self.typeBits(node.kind)) | UInt32(node.permissions)
        attributes.uid = node.uid
        attributes.gid = node.gid
        attributes.linkCount = node.linkCount
        attributes.size = node.size
        attributes.allocSize = node.allocatedSize
        attributes.fileID = FSItem.Identifier(rawValue: try tree.checkedMountID(for: node.id)) ?? .invalid
        attributes.parentID = FSItem.Identifier(rawValue: tree.parentMountID(of: node)) ?? .invalid
        attributes.accessTime = Self.timespec(node.accessed)
        attributes.modifyTime = Self.timespec(node.modified)
        attributes.changeTime = Self.timespec(node.changed)
        attributes.birthTime = Self.timespec(node.created)
        attributes.flags = node.isHidden ? UInt32(UF_HIDDEN) : 0
        // A file not stored as its bytes (inline, compressed, resident) is read by the module; every other one by the kernel
        // itself, through its block map. FSKit reads this once per file (roadmap 0018).
        if node.kind == .regular {
            let mappable = (tree.fileSystem as? any BlockMapping).flatMap { try? $0.isMappable(node.id) } ?? false
            attributes.inhibitKernelOffloadedIO = !mappable
        }
        return attributes
    }

    static func type(_ kind: NodeKind) -> FSItem.ItemType {
        switch kind {
            case .regular: .file
            case .directory: .directory
            case .symlink: .symlink
            case .fifo: .fifo
            case .characterDevice: .charDevice
            case .blockDevice: .blockDevice
            case .socket: .socket
        }
    }

    private static func typeBits(_ kind: NodeKind) -> mode_t {
        switch kind {
            case .regular: S_IFREG
            case .directory: S_IFDIR
            case .symlink: S_IFLNK
            case .fifo: S_IFIFO
            case .characterDevice: S_IFCHR
            case .blockDevice: S_IFBLK
            case .socket: S_IFSOCK
        }
    }

    private static func timespec(_ time: Timestamp) -> timespec {
        Darwin.timespec(tv_sec: Int(time.seconds), tv_nsec: Int(time.nanoseconds))
    }

    /// Answers `reply` for an operation on `item`: casts it, runs `body`, and turns reader errors into
    /// FSKit errors. A result FSKit's failable initializer refused is an internal error, never a crash.
    func answer<T>(
        _ item: FSItem, _ reply: (T?, (any Error)?) -> Void, _ what: String,
        _ body: (ReadOnlyItem) throws(DiskError) -> T?
    ) {
        guard let item = item as? ReadOnlyItem else { return reply(nil, ModuleError.invalid) }
        do throws(DiskError) {
            guard let result = try body(item) else { throw .corrupt("FSKit refused the \(what) result") }
            reply(result, nil)
        } catch {
            log.debug("\(what, privacy: .public): \(String(describing: error), privacy: .public)")
            reply(nil, error.fskit)
        }
    }
}
