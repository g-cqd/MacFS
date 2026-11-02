import CryptoKit
public import Foundation

/// The live write check (roadmap 0046): a copy of a test image with its own volume identity (a copy sharing an attached
/// image's would not mount), attached writable, mounted through its FSKit module without `rdonly`, changed in every way the
/// writer supports, unmounted, detached, then judged by the format's own checker on Linux: consistent, and holding what was
/// written. Each change is a command with a deadline: a write stuck in the kernel leaves a child behind, not this tool.
public struct WriteCheck: Sendable {
    public struct Target: Sendable, Equatable {
        public let image: String
        public let type: String
        /// Where the 16 bytes of the volume's UUID are (ext: `s_uuid` in the superblock).
        public let identityOffset: Int
        public init(image: String, type: String, identityOffset: Int) {
            self.image = image
            self.type = type
            self.identityOffset = identityOffset
        }
    }

    /// One session's files: the copy, the payload written to it, the mount point, and the SHA-256 of each file the checker
    /// should find (volume path to lowercase hex).
    public struct Workspace: Sendable, Equatable {
        public let image: String
        public let payload: String
        public let point: String
        public let expected: [String: String]
        public init(image: String, payload: String, point: String, expected: [String: String]) {
            self.image = image
            self.payload = payload
            self.point = point
            self.expected = expected
        }
    }

    /// The images whose format MacFS writes.
    public static let targets = [Target(image: "ext2", type: "ext4", identityOffset: 1024 + 0x68)]

    let runner: any ProcessRunning
    /// Waits before a mount's retry; the tests' does not.
    let pause: @Sendable (Duration) -> Void
    /// The format's checker on the released copy, with the hashes it should find: its problems.
    let checker: @Sendable (Target, String, [String: String]) -> [String]

    public init(
        runner: any ProcessRunning,
        pause: @escaping @Sendable (Duration) -> Void,
        checker: @escaping @Sendable (Target, String, [String: String]) -> [String]
    ) {
        self.runner = runner
        self.pause = pause
        self.checker = checker
    }

    public func run(_ target: Target, in workspace: Workspace) -> MountCheck.Outcome {
        let outcome = { (problems: [String]) in
            MountCheck.Outcome(
                target: MountCheck.Target(image: target.image, type: target.type, extra: []),
                problems: problems
            )
        }
        let session = MountSession(runner: runner, pause: pause)
        let (problems, mounted) = session.run(
            image: workspace.image,
            attach: [],
            type: target.type,
            mount: [],
            at: workspace.point
        ) {
            for command in Self.operations(point: workspace.point, payload: workspace.payload) {
                let result = try? runner.run(command)
                guard let result, result.status == 0 else {
                    let what = ([command.executable] + command.arguments).joined(separator: " ")
                    return ["\(what): \(result.map { "\($0.status) \($0.output)" } ?? "did not finish")"]
                }
            }
            return []
        }
        guard mounted else { return outcome(problems) }
        return outcome(problems + checker(target, workspace.image, workspace.expected))
    }

    /// The changes, in order, on the mount at `point`; `payload` is a host file. Ends with the files the checker hashes:
    /// `/renamed/moved.bin` and `/hard.bin` (the payload, one inode), `/short.bin` (100 bytes of it, then all of it).
    public static func operations(point: String, payload: String) -> [Command] {
        let at = { (name: String) in "\(point)/\(name)" }
        let rows: [[String]] = [
            ["/bin/cp", payload, at("written.bin")], ["/usr/bin/cmp", payload, at("written.bin")],
            ["/bin/mkdir", at("folder")], ["/bin/mv", at("written.bin"), at("folder/moved.bin")],
            ["/bin/ln", "-s", "moved.bin", at("folder/link")], ["/bin/ln", at("folder/moved.bin"), at("hard.bin")],
            ["/bin/cp", payload, at("gone.bin")], ["/bin/rm", at("gone.bin")],
            ["/bin/cp", payload, at("short.bin")], ["/usr/bin/truncate", "-s", "100", at("short.bin")],
            ["/bin/sh", "-c", "cat \"$1\" >> \"$2\"", "sh", payload, at("short.bin")],
            ["/bin/chmod", "600", at("folder/moved.bin")], ["/bin/mv", at("folder"), at("renamed")],
            ["/usr/bin/cmp", payload, at("renamed/link")]
        ]
        return rows.map { Command($0[0], Array($0.dropFirst())) }
    }

    /// A fresh session under `work`: the image copied with a random identity, a payload of 4 MiB and a partial block, and
    /// an empty mount point.
    public static func prepare(_ target: Target, root: String, in work: String) throws -> Workspace {
        let files = FileManager.default
        try files.createDirectory(atPath: work + "/point", withIntermediateDirectories: true)
        var image = try Data(contentsOf: URL(fileURLWithPath: "\(root)/TestImages/\(target.image).img"))
        let identity = withUnsafeBytes(of: UUID().uuid) { Data($0) }
        image.replaceSubrange(target.identityOffset ..< (target.identityOffset + 16), with: identity)
        let copy = "\(work)/\(target.image).img"
        try image.write(to: URL(fileURLWithPath: copy))
        var generator = SystemRandomNumberGenerator()
        let payload = Data((0 ..< (4 << 20) + 1234).map { _ in UInt8.random(in: 0 ... 255, using: &generator) })
        try payload.write(to: URL(fileURLWithPath: work + "/payload.bin"))
        let whole = sha256(payload)
        return Workspace(
            image: copy,
            payload: work + "/payload.bin",
            point: work + "/point",
            expected: [
                "/renamed/moved.bin": whole, "/hard.bin": whole, "/short.bin": sha256(payload.prefix(100) + payload)
            ]
        )
    }

    /// Lowercase hex, as `sha256sum` prints it.
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
