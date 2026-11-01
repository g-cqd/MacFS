import AemiProtobuf
import FSCore
import Foundation
import MountKit
import Testing

@testable import MountRegistry

/// A newer version's record: one field more (9), which this version must carry through a load and a save untouched.
@ProtoMessage struct NewerRecord {
    @ProtoField(1) var id: String = ""
    @ProtoField(2) var kind: Int32 = 0
    @ProtoField(3) var source: String = ""
    @ProtoField(4) var mountPoint: String = ""
    @ProtoField(5) var mountedFrom: String = ""
    @ProtoField(6) var state: Int32 = 0
    @ProtoField(9) var owner: Int32 = 0
}

@ProtoMessage struct NewerRegistry {
    @ProtoField(1) var records: [NewerRecord] = []
    @ProtoField(7) var note: String = ""
}

/// The registry on disk (ADR-0015): protobuf in an envelope (magic, version, length, CRC-32C), written atomically. Research
/// 2026-11-01 found protobuf alone accepts truncations at record boundaries and no format catches bit changes: the envelope
/// refuses every one, and a refused file is moved aside, never half-read.
@Suite struct ProtobufRegistryStoreTests {
    let directory: String
    var path: String { directory + "/registry.pb" }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("registry-\(UUID().uuidString)").path
    }

    static let records = [
        MountRecord(
            id: "a",
            kind: .nfs,
            source: "/i/a.img",
            mountPoint: "/m/a",
            mountedFrom: "127.0.0.1:/macfs-1",
            state: .mounted
        ),
        MountRecord(
            id: "b",
            kind: .fsKit,
            source: "/dev/disk4s1",
            mountPoint: "/m/b",
            mountedFrom: "",
            state: .pending
        ),
        MountRecord(
            id: "c",
            kind: .unrecognized(9),
            source: "/i/c.img",
            mountPoint: "/m/c",
            mountedFrom: "x",
            state: .unrecognized(4)
        ),
        MountRecord(
            id: "d",
            kind: .webDAV,
            source: "/i/d.img",
            mountPoint: "/m/ü d",
            mountedFrom: "http://127.0.0.1/x",
            state: .mounted
        )
    ]

    func written() throws -> [UInt8] { [UInt8](try Data(contentsOf: URL(fileURLWithPath: path))) }

    func write(_ bytes: [UInt8]) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try Data(bytes).write(to: URL(fileURLWithPath: path))
    }

    func quarantined() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.contains(".corrupt-") }
    }

    @Test func recordsRoundTrip() throws {
        try ProtobufRegistryStore(path: path).save(Self.records)
        #expect(try ProtobufRegistryStore(path: path).load() == Self.records)
    }

    /// Lengths beyond one byte, and a registry larger than any read a test of the envelope makes otherwise.
    @Test func aLargeRegistryRoundTrips() throws {
        let many = (0 ..< 2_000)
            .map {
                MountRecord(
                    id: "id\($0)",
                    kind: .nfs,
                    source: "/i/\($0).img",
                    mountPoint: "/m/\($0)",
                    mountedFrom: "f\($0)",
                    state: .mounted
                )
            }
        try ProtobufRegistryStore(path: path).save(many)
        #expect(try written().count > 65_536)
        #expect(try ProtobufRegistryStore(path: path).load() == many)
    }

    /// No records is a valid registry of 14 bytes, not a damaged one.
    @Test func anEmptyRegistryIsValid() throws {
        try ProtobufRegistryStore(path: path).save([])
        #expect(try written().count == 14)
        let store = ProtobufRegistryStore(path: path)
        #expect(try store.load().isEmpty)
        #expect(store.quarantine == nil && FileManager.default.fileExists(atPath: path))
    }

    @Test func noFileIsAnEmptyRegistry() throws {
        #expect(try ProtobufRegistryStore(path: path).load().isEmpty)
    }

    @Test func theFileIsEnvelopedAndPrivate() throws {
        try ProtobufRegistryStore(path: path).save(Self.records)
        let bytes = try written()
        #expect(Array(bytes.prefix(6)) == Array("MFSR".utf8) + [0, 1], "magic, then format version 1")
        let length = bytes[6 ..< 10].reduce(0) { $0 << 8 | Int($1) }
        #expect(bytes.count == 10 + length + 4)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory) == ["registry.pb"],
            "no temporary file left"
        )
    }

    /// Every truncation, including the record boundaries protobuf alone accepts, is refused and set aside.
    @Test func everyTruncationIsRefused() throws {
        try ProtobufRegistryStore(path: path).save(Self.records)
        let whole = try written()
        for length in 0 ..< whole.count {
            try write(Array(whole[0 ..< length]))
            let store = ProtobufRegistryStore(path: path)
            #expect(try store.load().isEmpty, "\(length) bytes")
            #expect(store.quarantine != nil || length == 0, "\(length) bytes")
            #expect(!FileManager.default.fileExists(atPath: path) || length == 0)
        }
    }

    /// Every one-bit change is refused (CRC-32C detects all of them), where 93% decoded to other values without the envelope.
    @Test func everyBitChangeIsRefused() throws {
        try ProtobufRegistryStore(path: path).save(Self.records)
        let whole = try written()
        var accepted: [Int] = []
        for index in whole.indices {
            for bit in [0, 3, 7] {
                var changed = whole
                changed[index] ^= 1 << bit
                try write(changed)
                if try !ProtobufRegistryStore(path: path).load().isEmpty { accepted.append(index) }
            }
        }
        #expect(accepted.isEmpty, "accepted with changes at \(accepted.prefix(5))")
        #expect(try quarantined().count == 3 * whole.count, "each refused file set aside, none overwritten")
    }

    /// A file of a newer format version is refused and left as it is: a newer MacFS's registry is not this version's to discard.
    @Test func aNewerFormatIsRefusedAndLeftAlone() throws {
        try ProtobufRegistryStore(path: path).save(Self.records)
        let payload = Array(try written().dropFirst(10).dropLast(4))
        func version(_ high: UInt8, _ low: UInt8) -> [UInt8] {
            var bytes = ProtobufRegistryStore.envelope(payload)
            (bytes[4], bytes[5]) = (high, low)  // a real file of that version: the checksum covers it
            let crc = CRC32C.checksum(bytes[0 ..< bytes.count - 4])
            for index in 0 ..< 4 { bytes[bytes.count - 4 + index] = UInt8(truncatingIfNeeded: crc >> (24 - 8 * index)) }
            return bytes
        }
        try write(version(1, 0))
        #expect(throws: MountError.registry("\(path): format version 256, newer than this MacFS reads (1)")) {
            try ProtobufRegistryStore(path: path).load()
        }
        let bytes = version(0, 2)
        try write(bytes)
        #expect(throws: MountError.registry("\(path): format version 2, newer than this MacFS reads (1)")) {
            try ProtobufRegistryStore(path: path).load()
        }
        #expect(try written() == bytes)
        #expect(try quarantined().isEmpty)
        #expect(throws: MountError.self) { try ProtobufRegistryStore(path: path).save([]) }
        #expect(try written() == bytes, "nor overwritten")
    }

    /// Fields of a newer version, in a record and in the registry, survive this version's load and save (ADR-0015): a downgrade
    /// followed by an upgrade loses nothing.
    @Test func aNewerVersionsFieldsSurviveALoadAndASave() throws {
        let newer = NewerRegistry(
            records: [
                NewerRecord(
                    id: "a",
                    kind: 1,
                    source: "/i/a.img",
                    mountPoint: "/m/a",
                    mountedFrom: "f",
                    state: 1,
                    owner: 501
                )
            ],
            note: "from 2.0"
        )
        try write(ProtobufRegistryStore.envelope(try ProtobufEncoder().encodeToBytes(newer)))
        let store = ProtobufRegistryStore(path: path)
        var records = try store.load()
        #expect(records.map(\.id) == ["a"])
        records.append(Self.records[1])
        try store.save(records)
        let bytes = try written()
        let back = try ProtobufDecoder().decode(NewerRegistry.self, fromBytes: Array(bytes[10 ..< bytes.count - 4]))
        #expect(back.note == "from 2.0")
        #expect(back.records.map(\.owner) == [501, 0])
    }
}
