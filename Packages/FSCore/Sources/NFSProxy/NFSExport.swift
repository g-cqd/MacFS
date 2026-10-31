import Darwin

/// The one export a proxy serves, as a capability (roadmap 0038): an unguessable path, and a secret every file handle carries.
/// The mount table shows a mount's source to every local user, so the path is secret only until it is mounted; the dispatcher
/// therefore admits a single MNT, and a process that skips MOUNT cannot build a handle without the secret.
public struct NFSExport: Sendable, Equatable {
    /// `/macfs-` and the token's first 16 bytes in hex.
    public let path: String
    /// The token's last 8 bytes, in every file handle.
    let secret: [UInt8]

    /// From 24 bytes of token: 16 name the path, 8 are the handles' secret.
    public init(token: [UInt8]) {
        precondition(token.count == 24, "an export token is 24 bytes")
        let digits = Array("0123456789abcdef".utf8)
        var hex: [UInt8] = []
        for byte in token.prefix(16) { hex += [digits[Int(byte >> 4)], digits[Int(byte & 0xF)]] }
        path = "/macfs-" + String(decoding: hex, as: UTF8.self)
        secret = Array(token.suffix(8))
    }

    /// A fresh export from the system's random generator.
    public static func random() -> NFSExport {
        var token = [UInt8](repeating: 0, count: 24)
        token.withUnsafeMutableBytes { unsafe arc4random_buf($0.baseAddress, $0.count) }
        return NFSExport(token: token)
    }
}
