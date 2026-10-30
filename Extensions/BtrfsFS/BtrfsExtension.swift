import ExtensionFoundation
import FSKit
import Formats

/// The Btrfs module. All behaviour is in Extensions/Shared; this names the format.
@main
struct BtrfsExtension: UnaryFileSystemExtension {
    let fileSystem = ReadOnlyModule(format: .btrfs)
}
