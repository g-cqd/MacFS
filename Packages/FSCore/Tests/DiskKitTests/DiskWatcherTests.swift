import DiskKit
import Dispatch
import Formats
import Foundation
import Synchronization
import Testing

/// The watcher, live (roadmap 0021): an image attached, automounted by our ext4 module, then detached. Disk Arbitration first
/// reports every disk already attached as appeared; the test follows only the image's.
@Suite(.serialized) struct DiskWatcherTests {
    static let image = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent(
            "../../../../TestImages/ext4.img"
        )
        .standardizedFileURL.path

    final class Events: Sendable {
        let seen = Mutex<[DiskEvent]>([])
        func of(_ id: String) -> [DiskEvent] {
            seen.withLock { events in
                events.filter {
                    switch $0 {
                        case .appeared(let disk), .changed(let disk): disk.id == id
                        case .disappeared(let disk): disk == id
                    }
                }
            }
        }
    }

    static func hdiutil(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output
    }

    /// Polls `condition` for up to `seconds`.
    static func eventually(_ seconds: Int, _ condition: () -> Bool) async throws -> Bool {
        for _ in 0 ..< seconds * 10 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: image)))
    func anAttachedImageAppearsIsMountedAndDisappears() async throws {
        let events = Events()
        let watcher = DiskWatcher(queue: DispatchQueue(label: "test.diskwatcher")) { event in
            events.seen.withLock { $0.append(event) }
        }
        defer { watcher.stop() }
        let attached = try Self.hdiutil(["attach", "-readonly", Self.image])
        let id = try #require(attached.split(separator: "\n").first?.split(separator: "\t").first)
            .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/dev/", with: "")
        defer { _ = try? Self.hdiutil(["detach", "-force", "/dev/" + id]) }

        #expect(
            try await Self.eventually(20) {
                events.of(id)
                    .contains {
                        if case .changed(let disk) = $0 { disk.volume?.path != nil } else { false }
                    }
            },
            "no change carrying the mount path"
        )
        let first = try #require(events.of(id).first)
        guard case .appeared(let disk) = first else {
            Issue.record("the first event was \(first), not an appearance")
            return
        }
        #expect(disk.reader == .macFS(.ext))

        _ = try Self.hdiutil(["detach", "/dev/" + id])
        #expect(try await Self.eventually(20) { events.of(id).last == .disappeared(id) }, "no disappearance")
    }

    /// A stopped watcher reports nothing more: not even an image attached after.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: image)))
    func aStoppedWatcherIsSilent() async throws {
        let events = Events()
        let watcher = DiskWatcher(queue: DispatchQueue(label: "test.diskwatcher.stopped")) { event in
            events.seen.withLock { $0.append(event) }
        }
        // Every attached disk is reported at once, the boot disk among them.
        #expect(try await Self.eventually(10) { !events.seen.withLock(\.isEmpty) })
        watcher.stop()
        let count = events.seen.withLock(\.count)
        let attached = try Self.hdiutil(["attach", "-readonly", "-nomount", Self.image])
        let id = try #require(attached.split(separator: "\n").first?.split(separator: "\t").first)
            .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/dev/", with: "")
        defer { _ = try? Self.hdiutil(["detach", "-force", "/dev/" + id]) }
        try await Task.sleep(for: .seconds(2))
        #expect(events.seen.withLock(\.count) == count)
    }
}
