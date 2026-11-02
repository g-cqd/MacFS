public import FSCore
import Synchronization

/// Kernel-offloaded writes (roadmap 0046): the range's blocks made as an allocating write makes them (new ones zeroed,
/// written and flushed before they are linked), the map answered from the runs, past the file's end too.
extension ExtFileSystem: WritableBlockMapping {
    public func mapForWriting(_ id: UInt64, offset: UInt64, length: UInt64) throws(DiskError) -> [MappedRange] {
        try serialized { () throws(DiskError) -> [MappedRange] in
            let device = try openDevice()
            let inode = try regularFile(id, "mapping for writing")
            guard length > 0 else { return [] }
            let blockSize = UInt64(superblock.blockSize)
            let end = offset + length
            let runs = try runs(inode, through: (end - 1) / blockSize)
            if Self.pieces(of: runs, from: offset, to: end, blockSize: blockSize) == nil {
                try freeCounts.withLock { (free) throws(DiskError) in
                    free = try allocatingWrite(
                        inode,
                        at: offset,
                        nil,
                        length: length,
                        on: device,
                        free: free ?? initialFreeCounts
                    )
                }
            }
            let first = offset / blockSize * blockSize
            let last = (end + blockSize - 1) / blockSize * blockSize
            var map: [MappedRange] = []
            for run in try self.runs(try self.inode(id), through: (end - 1) / blockSize) {
                let from = max(first, run.logical * blockSize)
                let to = min(last, run.end * blockSize)
                guard from < to else { continue }
                guard let physical = run.physical else {
                    throw .corrupt("inode \(id): a hole left in a range mapped for writing")
                }
                map.append(
                    MappedRange(
                        logical: from,
                        length: to - from,
                        physical: physical * blockSize + (from - run.logical * blockSize)
                    )
                )
            }
            return map
        }
    }

    public func completeWrite(_ id: UInt64, offset: UInt64, length: UInt64) throws(DiskError) {
        try serialized { () throws(DiskError) in
            let device = try openDevice()
            let inode = try regularFile(id, "completing a write to")
            let size = max(inode.size, offset + length)
            // The kernel's data durable before the size covers it: a crash never shows a size past what was written.
            try device.flush()
            try touch(inode, on: device) { raw in
                Self.put32(UInt32(truncatingIfNeeded: size), at: 0x04, in: &raw)
                Self.put32(UInt32(truncatingIfNeeded: size >> 32), at: 0x6C, in: &raw)
            }
        }
    }
}
