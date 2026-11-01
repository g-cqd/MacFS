import Darwin
import FSCore
import Formats
public import MountKit

extension NFSMountBackend {
    /// The backend as the agent and `macfs-nfsd` run it: system commands, this user as owner, any volume `DiskFormat` reads.
    public static func system(table: any MountTable) -> NFSMountBackend {
        NFSMountBackend(runner: SystemCommandRunner(), table: table, owner: (getuid(), getgid())) { path in
            let source = try FileBlockSource(path: path)
            guard let format = DiskFormat.detect(source) else { throw DiskError.unsupported("no volume MacFS reads") }
            return try MountedTree(try format.open(source))
        }
    }
}
