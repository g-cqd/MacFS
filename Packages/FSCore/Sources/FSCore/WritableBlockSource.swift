/// A ``BlockSource`` that also takes writes (ADR-0018).
///
/// `flush` is a barrier: every write before it is durable once it returns. Writes between two flushes may reach the medium in
/// any order, or not at all, if power is lost; the crash tests replay exactly that.
public protocol WritableBlockSource: BlockSource {
    /// `bytes` at `offset`. A write past the end throws and changes nothing.
    func write(at offset: UInt64, _ bytes: [UInt8]) throws(DiskError)
    func flush() throws(DiskError)
}
