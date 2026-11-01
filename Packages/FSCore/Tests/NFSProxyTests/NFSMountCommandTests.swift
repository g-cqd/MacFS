import NFSProxy
import Testing

/// How the proxy is mounted (roadmap 0038): soft, with a bounded dead timeout, so the kernel unmounts a proxy that died instead
/// of hanging every reader of the mount, which is Everest's worst failure (a hard mount, the default, waits forever).
@Suite struct NFSMountCommandTests {
    let command = NFSMountCommand(
        port: 4_049,
        export: NFSExport(token: Array(0 ..< 24)),
        mountPoint: "/Users/u/Library/Application Support/MacFS/Mounts/x"
    )

    var options: [String] {
        guard let index = command.arguments.firstIndex(of: "-o") else { return [] }
        return command.arguments[index + 1].split(separator: ",").map(String.init)
    }

    @Test func itRunsMacOSsOwnClient() {
        #expect(command.executable == "/sbin/mount_nfs")
        #expect(
            command.arguments.suffix(2) == ["127.0.0.1:/macfs-000102030405060708090a0b0c0d0e0f", command.mountPoint]
        )
    }

    @Test func aDeadProxyIsUnmountedNotWaitedFor() {
        #expect(options.contains("soft"))
        #expect(options.contains("intr"))
        #expect(!options.contains("hard"))
        #expect(options.contains("deadtimeout=\(NFSMountCommand.deadTimeout)"))
        #expect((1 ... 60).contains(NFSMountCommand.deadTimeout), "bounded, and no longer than the system's own 60 s")
    }

    /// The client's default for TCP is 32 KiB; at 128 KiB (the proxy's FSINFO rtpref) a cold read of the bench images ran 1.4 to
    /// 1.6 times faster (docs/conformance/performance.md).
    @Test func itReadsInTheProxysPreferredSize() {
        #expect(options.contains("rsize=131072"))
    }

    /// ADR-0014's numbers: ten seconds before a dead proxy is unmounted, 128 KiB reads.
    @Test func theNumbersAreADR0014s() {
        #expect(NFSMountCommand.deadTimeout == 10)
        #expect(NFSMountCommand.readSize == 131_072)
    }

    @Test func itReachesTheProxyWithoutAPortmapper() {
        for option in ["vers=3", "tcp", "port=4049", "mountport=4049", "rdonly", "locallocks"] {
            #expect(options.contains(option), "\(option)")
        }
    }
}
