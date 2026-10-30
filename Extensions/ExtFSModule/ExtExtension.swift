import ExtensionFoundation
import FSKit
import Formats

/// The Ext module. All behaviour is in Extensions/Shared; this names the format.
@main
struct ExtExtension: UnaryFileSystemExtension {
    let fileSystem = ReadOnlyModule(format: .ext)
}
