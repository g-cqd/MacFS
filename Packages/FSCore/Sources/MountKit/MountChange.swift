/// The result of moving a mount to another backend: the new record, and whether the old mount went (when it did not, both stay
/// on record for the sweep or the user).
public struct MountChange: Hashable, Sendable {
    public let record: MountRecord
    public let oldUnmounted: Bool

    public init(record: MountRecord, oldUnmounted: Bool) {
        self.record = record
        self.oldUnmounted = oldUnmounted
    }
}
