import FSCore

/// The ext2/ext3 block map: twelve direct pointers, then single, double and triple indirect blocks.
enum ExtIndirectMap {
    /// Runs covering logical blocks `[first, first + count)`, merged where physically contiguous.
    static func runs(
        _ area: DiskBytes,
        first: UInt64,
        count: UInt64,
        blockSize: Int,
        readBlock: (UInt64) throws(DiskError) -> DiskBytes
    ) throws(DiskError) -> [ExtRun] {
        let perBlock = UInt64(blockSize / 4)
        var runs: [ExtRun] = []
        for logical in first ..< (first + count) {
            let physical = try lookup(logical, area: area, perBlock: perBlock, readBlock: readBlock)
            if let last = runs.last, last.end == logical,
                (last.physical == nil && physical == nil)
                    || (last.physical.map { physical == $0 + last.count } ?? false)
            {
                runs[runs.count - 1] = ExtRun(logical: last.logical, physical: last.physical, count: last.count + 1)
            } else {
                runs.append(ExtRun(logical: logical, physical: physical, count: 1))
            }
        }
        return runs
    }

    private static func lookup(
        _ logical: UInt64,
        area: DiskBytes,
        perBlock: UInt64,
        readBlock: (UInt64) throws(DiskError) -> DiskBytes
    ) throws(DiskError) -> UInt64? {
        var index = logical
        if index < 12 { return try pointer(area, Int(index)) }
        index -= 12
        // Level n covers perBlock^n blocks through slot 11 + n of i_block.
        var span = perBlock
        for level in 1 ... 3 {
            if index < span {
                guard var block = try pointer(area, 11 + level) else { return nil }
                var remaining = span
                for _ in 0 ..< level {
                    remaining /= perBlock
                    guard let next = try pointer(try readBlock(block), Int(index / remaining)) else { return nil }
                    index %= remaining
                    block = next
                }
                return block
            }
            index -= span
            span *= perBlock
        }
        throw .corrupt("logical block \(logical) is past the triple-indirect range")
    }

    private static func pointer(_ bytes: DiskBytes, _ slot: Int) throws(DiskError) -> UInt64? {
        let value = try bytes.u32(4 * slot)
        return value == 0 ? nil : UInt64(value)
    }
}
