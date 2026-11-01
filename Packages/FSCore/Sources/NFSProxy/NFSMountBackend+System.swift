import AemiIO
import Darwin
import FSCore
import Formats
public import MountKit

extension NFSMountBackend {
    /// The backend as the agent and `macfs-nfsd` run it: system commands, this user as owner, any volume `DiskFormat` reads, from
    /// a handed descriptor when there is one.
    public static func system(table: any MountTable) -> NFSMountBackend {
        NFSMountBackend(runner: SystemCommandRunner(), table: table, owner: (getuid(), getgid())) { request in
            // The app's descriptor when it sent one (the agent need not be allowed to open the path), else the path.
            let source =
                try request.descriptor.map { try FileBlockSource(file: PosixFile(borrowing: $0)) }
                ?? FileBlockSource(path: request.source)
            guard let format = DiskFormat.detect(source) else { throw DiskError.unsupported("no volume MacFS reads") }
            return try MountedTree(try format.open(source))
        }
    }
}
