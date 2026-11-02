import ExtFS
import FSCore
import Foundation
import MountKit
import NFSProxy
import Testing

/// A writable proxy mount (roadmap 0046): asked for by the request, served writable only when the volume's writer began, and
/// the writer closed (the volume clean again) once the mount is gone.
@Suite struct NFSWritableMountTests {
    let system = FakeSystem()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nfswritable-\(UUID().uuidString)")
        .path

    /// The ext superblock's state: bit 0 is clean.
    static func isClean(_ device: MemoryBlockSource) throws -> Bool {
        try device.read(at: 1024 + 0x3A, count: 1)[0] & 1 != 0
    }

    func backend(writer: Bool, device: MemoryBlockSource) -> NFSMountBackend {
        NFSMountBackend(runner: system, table: system, owner: (501, 20)) { request in
            #expect(request.writable)
            guard writer else { return OpenedVolume(try MountedTree(try ExtFileSystem(source: device))) }
            let volume = try ExtFileSystem(writable: device, clock: { .now })
            return OpenedVolume(try MountedTree(volume), writer: volume)
        }
    }

    func options() throws -> [String] {
        try #require(system.ran.first)[2].split(separator: ",").map(String.init)
    }

    @Test func aWritableRequestWithAWriterMountsWritableAndClosesItAtUnmount() throws {
        let session = try NFSWriteSession(writable: false)
        let device = session.device
        let backend = backend(writer: true, device: device)
        let request = MountRequest(id: "w", source: "/i/a.img", mountPoint: directory + "/w", writable: true)
        let from = try backend.mount(request)
        #expect(try !options().contains("rdonly"))
        #expect(try !Self.isClean(device), "writing: not clean while mounted")
        try backend.unmount(
            MountRecord(
                id: "w",
                kind: .nfs,
                source: "/i/a.img",
                mountPoint: directory + "/w",
                mountedFrom: from,
                state: .mounted
            )
        )
        #expect(try Self.isClean(device), "the writer closed: clean again")
    }

    @Test func aVolumeWithoutAWriterMountsReadOnlyEvenWhenAsked() throws {
        let session = try NFSWriteSession(writable: false)
        let backend = backend(writer: false, device: session.device)
        _ = try backend.mount(MountRequest(id: "r", source: "/i/a.img", mountPoint: directory + "/r", writable: true))
        #expect(try options().contains("rdonly"))
    }
}
