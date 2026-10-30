import ExtensionFoundation
import FSKit
import Formats

/// The NTFS module. All behaviour is in Extensions/Shared; this names the format.
@main
struct NTFSExtension: UnaryFileSystemExtension {
    let fileSystem = ReadOnlyModule(format: .ntfs)
}
