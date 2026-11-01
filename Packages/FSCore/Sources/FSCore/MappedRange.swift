/// A piece of a file as it lies on the device (roadmap 0018): `length` bytes at `logical` in the file, at `physical` on the
/// device, or zero when `physical` is nil (a hole, an unwritten extent, past an initialized size).
public struct MappedRange: Sendable, Equatable {
    public let logical: UInt64
    public let length: UInt64
    public let physical: UInt64?

    public init(logical: UInt64, length: UInt64, physical: UInt64?) {
        self.logical = logical
        self.length = length
        self.physical = physical
    }

    /// `ranges` (a file's, ascending, in bytes) cut to the units covering [`offset`, `offset + length`) and to the file's last
    /// unit, with every gap between them zero: what a block map answers.
    public static func clip(
        _ ranges: [MappedRange],
        offset: UInt64,
        length: UInt64,
        size: UInt64,
        unit: UInt64
    ) -> [MappedRange] {
        guard unit > 0 else { return [] }
        let start = offset / unit * unit
        let fileEnd = size.isMultiple(of: unit) ? size : (size / unit + 1) * unit
        let wanted = offset.addingReportingOverflow(length)
        let requestEnd = wanted.overflow ? UInt64.max / unit * unit : (wanted.partialValue + unit - 1) / unit * unit
        let end = min(fileEnd, requestEnd)
        guard start < end else { return [] }
        var result: [MappedRange] = []
        var cursor = start
        for range in ranges where range.logical + range.length > cursor && range.logical < end {
            let from = max(range.logical, cursor)
            let to = min(range.logical + range.length, end)
            if from > cursor { result.append(MappedRange(logical: cursor, length: from - cursor, physical: nil)) }
            result.append(
                MappedRange(
                    logical: from,
                    length: to - from,
                    physical: range.physical.map { $0 + from - range.logical }
                )
            )
            cursor = to
        }
        if cursor < end { result.append(MappedRange(logical: cursor, length: end - cursor, physical: nil)) }
        return result
    }
}
