import FSKit

/// The FSKit item for one node; it carries only the mount identifier (``MountedTree``).
/// `@unchecked Sendable`: its one stored property is immutable, and FSKit passes items between queues.
final class ReadOnlyItem: FSItem, @unchecked Sendable {
    let mountID: UInt64

    init(mountID: UInt64) {
        self.mountID = mountID
        super.init()
    }
}
