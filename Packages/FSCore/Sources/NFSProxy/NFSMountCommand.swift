/// The `mount_nfs` command for a proxy (roadmap 0038). Soft, with a bounded dead timeout: when the proxy dies the kernel fails
/// its calls and then unmounts it, where a hard mount (the default) hangs every reader forever, which is the failure Everest
/// lived with. Read-only, local locks, and the one port for NFS and MOUNT (no portmapper, ADR-0010).
public struct NFSMountCommand: Sendable, Equatable {
    /// Seconds a mount may stay unresponsive before the kernel marks it dead and unmounts it (`deadtimeout`).
    public static let deadTimeout = 10
    /// Bytes per READ: the proxy's preferred size (FSINFO rtpref), four times the client's TCP default, measured faster.
    public static let readSize = 1 << 17

    public let executable = "/sbin/mount_nfs"
    public let port: UInt16
    public let export: NFSExport
    public let mountPoint: String

    public init(port: UInt16, export: NFSExport, mountPoint: String) {
        self.port = port
        self.export = export
        self.mountPoint = mountPoint
    }

    public var options: String {
        [
            "vers=3", "tcp", "port=\(port)", "mountport=\(port)", "rdonly", "soft", "intr",
            "deadtimeout=\(Self.deadTimeout)", "locallocks", "rsize=\(Self.readSize)"
        ]
        .joined(separator: ",")
    }

    public var arguments: [String] { ["-o", options, "127.0.0.1:\(export.path)", mountPoint] }
}
