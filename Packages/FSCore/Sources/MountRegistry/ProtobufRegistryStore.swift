import AemiProtobuf
import Darwin
import FSCore
import Foundation
public import MountKit
import Synchronization

/// The mount registry in a file (ADR-0015): `MFSR`, a big-endian format version (1) and length, the protobuf message, and the
/// CRC-32C of everything before it. A file that fails a check is moved aside (`.corrupt-<time>`) and the registry starts empty,
/// so nothing is half-read; a file of a newer format is refused and left alone. Saves go to a temporary file, synced, renamed.
/// Fields a newer version added survive a load and a save: they are kept per record and re-attached.
public final class ProtobufRegistryStore: MountRegistryStore {
    static let magic = Array("MFSR".utf8)
    static let version: UInt16 = 1

    public let path: String
    private let state = Mutex<State>(State())

    private struct State {
        /// Unknown fields per record id, and of the registry message, as last loaded.
        var unknown: [String: UnknownFields] = [:]
        var registryUnknown = UnknownFields()
        /// Where the last refused file was moved.
        var quarantine: String?
        /// A newer format was found: never write over it.
        var newer: MountError?
    }

    public init(path: String) { self.path = path }

    /// Where the last refused registry was set aside, for diagnostics.
    public var quarantine: String? { state.withLock { $0.quarantine } }

    public func load() throws(MountError) -> [MountRecord] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let bytes = [UInt8](data)
        if let error = newerFormat(bytes) {
            state.withLock { $0.newer = error }
            throw error
        }
        guard let payload = Self.payload(bytes),
            let message = try? ProtobufDecoder().decode(RegistryMessage.self, fromBytes: Array(payload))
        else {
            setAside()
            return []
        }
        state.withLock { state in
            state.registryUnknown = message.unknownFields
            state.unknown = Dictionary(message.records.map { ($0.id, $0.unknownFields) }) { first, _ in first }
        }
        return message.records.map(\.record)
    }

    public func save(_ records: [MountRecord]) throws(MountError) {
        let (newer, unknown, registryUnknown) = state.withLock { ($0.newer, $0.unknown, $0.registryUnknown) }
        if let newer { throw newer }
        // Also without a load: a newer MacFS's registry is never written over.
        if let data = FileManager.default.contents(atPath: path), let error = newerFormat([UInt8](data)) { throw error }
        var message = RegistryMessage(
            records: records.map { RecordMessage($0, unknownFields: unknown[$0.id] ?? UnknownFields()) }
        )
        message.unknownFields = registryUnknown
        let bytes: [UInt8]
        do { bytes = Self.envelope(try ProtobufEncoder().encodeToBytes(message)) } catch {
            throw .registry("\(path): \(error)")
        }
        try write(bytes)
    }

    // MARK: - Envelope

    static func envelope(_ payload: [UInt8]) -> [UInt8] {
        var bytes = magic + [UInt8(version >> 8), UInt8(version & 0xFF)]
        bytes += (0 ..< 4).map { UInt8(truncatingIfNeeded: UInt32(payload.count) >> (24 - 8 * $0)) }
        bytes += payload
        let crc = CRC32C.checksum(bytes[...])
        return bytes + (0 ..< 4).map { UInt8(truncatingIfNeeded: crc >> (24 - 8 * $0)) }
    }

    /// The envelope's layout and checksum are the same in every format version, so a newer file is told from a damaged one:
    /// only an intact envelope of a higher version is newer.
    private func newerFormat(_ bytes: [UInt8]) -> MountError? {
        guard Self.intact(bytes) != nil else { return nil }
        let version = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        guard version > Self.version else { return nil }
        return .registry("\(path): format version \(version), newer than this MacFS reads (\(Self.version))")
    }

    /// The message, if the envelope holds and is of this version.
    static func payload(_ bytes: [UInt8]) -> ArraySlice<UInt8>? {
        guard let payload = intact(bytes), bytes[4] == 0, bytes[5] == 1 else { return nil }
        return payload
    }

    /// The message, if the envelope holds whatever its version: magic, a length that fills the file, its CRC-32C.
    static func intact(_ bytes: [UInt8]) -> ArraySlice<UInt8>? {
        guard bytes.count >= 14, Array(bytes.prefix(4)) == magic else { return nil }
        let length = bytes[6 ..< 10].reduce(0) { $0 << 8 | Int($1) }
        guard bytes.count == 10 + length + 4 else { return nil }
        let stored = bytes[(10 + length)...].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard CRC32C.checksum(bytes[0 ..< 10 + length]) == stored else { return nil }
        return bytes[10 ..< 10 + length]
    }

    // MARK: - Files

    private func setAside() {
        var target = "\(path).corrupt-\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        // two in one microsecond
        if FileManager.default.fileExists(atPath: target) { target += "-" + UUID().uuidString }
        if (try? FileManager.default.moveItem(atPath: path, toPath: target)) != nil {
            state.withLock { $0.quarantine = target }
        }
    }

    /// Temporary file (mode 0600), `fsync`, rename over the registry, `fsync` of the directory.
    private func write(_ bytes: [UInt8]) throws(MountError) {
        let directory = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch { throw .registry("\(directory): \(error)") }
        let temporary = "\(path).tmp-\(getpid())"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw .registry("\(temporary): errno \(errno)") }
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { unsafe Darwin.write(fd, $0.baseAddress! + written, $0.count - written) }
            guard count > 0 else {
                let code = errno
                close(fd)
                unlink(temporary)
                throw .registry("\(temporary): errno \(code)")
            }
            written += count
        }
        let synced = fsync(fd) == 0
        close(fd)
        guard synced, rename(temporary, path) == 0 else {
            let code = errno
            unlink(temporary)
            throw .registry("\(path): errno \(code)")
        }
        // Until the directory is flushed, a crash can bring the old file back: a save that cannot flush it has failed
        // (fcheck's replace-not-durable found the path that skipped it when the directory did not open).
        let directoryFD = open(directory, O_RDONLY)
        guard directoryFD >= 0 else { throw .registry("\(directory): errno \(errno), the registry is not flushed") }
        let flushed = fsync(directoryFD) == 0
        let code = errno
        close(directoryFD)
        guard flushed else { throw .registry("\(directory): errno \(code), the registry is not flushed") }
    }
}
