import FSCore

/// A changing procedure's failure, as the `nfsstat3` it answers (roadmap 0046).
struct NFSFailure: Error, Equatable {
    let status: UInt32

    init(_ status: UInt32) { self.status = status }

    /// A reader's or writer's error as NFS names it.
    init(_ error: DiskError) { status = NFSStatus.of(error) }

    /// `body`'s result, its error answered as NFS names it.
    static func attempt<T>(_ body: () throws(DiskError) -> T) throws(NFSFailure) -> T {
        do throws(DiskError) { return try body() } catch { throw NFSFailure(error) }
    }
}
