extension NodeKind {
    /// From the file-type bits of a POSIX mode (`S_IFMT`), as Btrfs and ext store it.
    public init(posixMode mode: UInt32) {
        // @dl:accept -- two different on-disk encodings that map to the same cases
        switch mode & 0o170000 {
            case 0o040000: self = .directory
            case 0o120000: self = .symlink
            case 0o010000: self = .fifo
            case 0o020000: self = .characterDevice
            case 0o060000: self = .blockDevice
            case 0o140000: self = .socket
            default: self = .regular
        }
    }

    /// From a Linux directory-entry type (`DT_*` as Btrfs and ext's `filetype` feature encode it).
    public init(linuxDirectoryType type: UInt8) {
        // @dl:accept -- two different on-disk encodings that map to the same cases
        switch type {
            case 2: self = .directory
            case 3: self = .characterDevice
            case 4: self = .blockDevice
            case 5: self = .fifo
            case 6: self = .socket
            case 7: self = .symlink
            default: self = .regular
        }
    }
}
