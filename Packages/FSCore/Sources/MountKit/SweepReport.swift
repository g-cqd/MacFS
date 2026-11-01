/// What a sweep did with each record: kept (live), unmounted (ours, no longer served), forgotten (its mount is gone or is
/// someone else's), skipped (unrecognized, left alone).
public struct SweepReport: Hashable, Sendable {
    public var kept: [String] = []
    public var unmounted: [String] = []
    public var forgotten: [String] = []
    public var skipped: [String] = []
    /// Records the sweep wanted to unmount but could not: still on record.
    public var failed: [String] = []
    /// The registry could not be written after the sweep.
    public var unsaved = false

    public init() {}
}
