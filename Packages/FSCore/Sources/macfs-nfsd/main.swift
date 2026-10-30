import Darwin
import FSCore
import Formats
import Foundation
import MountKit
import NFSProxy

// macfs-nfsd <image-or-device> [--port N]
//
// Serves a Btrfs, NTFS or ext volume read-only over NFSv3 on 127.0.0.1 and prints the command that mounts it
// with macOS's own client. No portmapper: the port is given to mount_nfs for both NFS and MOUNT.

let arguments = Array(CommandLine.arguments.dropFirst())
guard let path = arguments.first else {
    print("usage: macfs-nfsd <image-or-device> [--port N]")
    exit(64)
}
var port: UInt16 = 0
if let index = arguments.firstIndex(of: "--port"), index + 1 < arguments.count, let value = UInt16(arguments[index + 1])
{
    port = value
}

do {
    let source = try FileBlockSource(path: path)
    guard let format = DiskFormat.detect(source) else {
        print("\(path): no Btrfs, NTFS or ext volume")
        exit(1)
    }
    let tree = try MountedTree(try format.open(source))
    let server = try LoopbackServer(dispatcher: NFSDispatcher(tree: tree, owner: (getuid(), getgid())), port: port)
    let options = "vers=3,tcp,port=\(server.port),mountport=\(server.port),rdonly,locallocks"
    print("serving \(format.displayName) \"\(tree.fileSystem.volume.label)\" on 127.0.0.1:\(server.port)")
    print("mount_nfs -o \(options) 127.0.0.1:/ <directory>")
    fflush(stdout)
    signal(SIGPIPE, SIG_IGN)
    while true { sleep(3600) }
} catch {
    print("macfs-nfsd: \(error)")
    exit(1)
}
