import ExtensionFoundation
import FSKit
import Formats

/// The XFS module. All behaviour is in Extensions/Shared; this names the format.
@main
struct XFSExtension: UnaryFileSystemExtension {
    let fileSystem = ReadOnlyModule(format: .xfs)
}
