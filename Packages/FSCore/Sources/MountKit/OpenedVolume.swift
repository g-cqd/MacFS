public import FSCore

/// A volume opened for a mount: its tree, and its writer when the mount was asked writable and the format's writer began
/// (roadmap 0046). The writer is closed once the mount is gone.
public struct OpenedVolume: Sendable {
    public let tree: MountedTree
    public let writer: (any WritableFileSystem)?

    public init(_ tree: MountedTree, writer: (any WritableFileSystem)? = nil) {
        self.tree = tree
        self.writer = writer
    }
}
