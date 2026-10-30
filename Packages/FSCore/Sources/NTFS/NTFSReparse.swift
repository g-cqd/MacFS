import FSCore

/// Reparse points that read as symbolic links: Windows symlinks, junctions, and WSL symlinks.
enum NTFSReparse {
    static let symlink: UInt32 = 0xA000_000C
    static let mountPoint: UInt32 = 0xA000_0003
    static let wslSymlink: UInt32 = 0xA000_001D

    static func isLink(tag: UInt32) -> Bool { tag == symlink || tag == mountPoint || tag == wslSymlink }

    /// The link target with `/` separators. Windows targets keep their print name (`C:/x` for an
    /// absolute one, which macOS cannot follow; relative ones resolve).
    static func target(_ value: DiskBytes) throws(DiskError) -> [UInt8] {
        let tag = try value.u32(0)
        let length = Int(try value.u16(4))
        let data = try value.slice(8, length)
        switch tag {
            case wslSymlink:
                guard try data.u32(0) == 2 else { throw .unsupported("WSL symlink version \(try data.u32(0))") }
                return try data.bytes(4, data.count - 4)
            case symlink, mountPoint:
                let buffer = tag == symlink ? 12 : 8
                let printOffset = Int(try data.u16(4))
                let printLength = Int(try data.u16(6))
                let name = UTF16Name.utf8(try data.slice(buffer + printOffset, printLength))
                return name.map { $0 == UInt8(ascii: "\\") ? UInt8(ascii: "/") : $0 }
            default:
                throw .notSymlink
        }
    }
}
