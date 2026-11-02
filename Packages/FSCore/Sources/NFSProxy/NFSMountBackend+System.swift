import AemiIO
import Darwin
import FSCore
import Formats
public import MountKit
import SystemCommands

extension NFSMountBackend {
    /// The backend as the agent and `macfs-nfsd` run it: system commands, this user as owner, any volume `DiskFormat` reads, from
    /// a handed descriptor when there is one; writable when asked and the format's writer accepts the volume.
    public static func system(table: any MountTable) -> NFSMountBackend {
        NFSMountBackend(runner: SystemCommandRunner(), table: table, owner: (getuid(), getgid())) { request in
            // The app's descriptor when it sent one (the agent need not be allowed to open the path), else the path. Writable
            // only when asked, and through a descriptor only when it was opened for writing.
            let source: FileBlockSource
            if let descriptor = request.descriptor {
                let writable = request.writable && fcntl(descriptor, F_GETFL) & O_ACCMODE == O_RDWR
                source = try FileBlockSource(file: PosixFile(borrowing: descriptor), writable: writable)
            } else {
                source = try FileBlockSource(path: request.source, writable: request.writable)
            }
            guard let format = DiskFormat.detect(source) else { throw DiskError.unsupported("no volume MacFS reads") }
            let fileSystem = try format.open(source)
            let tree = try MountedTree(fileSystem)
            // A format that does not write, or refuses this volume, mounts read-only (ADR-0018: asking never fails a mount).
            guard request.writable, source.isWritable, let writer = fileSystem as? any WritableFileSystem else {
                return OpenedVolume(tree)
            }
            do { try writer.beginWriting(on: source) } catch { return OpenedVolume(tree) }
            return OpenedVolume(tree, writer: writer)
        }
    }
}
