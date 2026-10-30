import FSCore
import FSKit
import Formats
import MountKit
import os

/// One FSKit module per format, all read-only: the format is the only difference (ADR-0006).
final class ReadOnlyModule: FSUnaryFileSystem, FSUnaryFileSystemOperations, @unchecked Sendable {
    // FSKit calls the operations serially on its own queue; `volume` is only touched there.
    private let format: DiskFormat
    private var volume: ReadOnlyVolume?
    private let log: Logger

    init(format: DiskFormat) {
        self.format = format
        self.log = Logger(subsystem: "dev.gcqd.MacFS.\(format.rawValue)", category: "module")
        super.init()
    }

    func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let device = resource as? FSBlockDeviceResource else { return replyHandler(.notRecognized, nil) }
        let description = format.probe(BlockDeviceSource(device))
        switch ProbeAnswer(description) {
            case .notRecognized:
                replyHandler(.notRecognized, nil)
            case .usable(let name):
                let container = description.map { FSContainerIdentifier(uuid: $0.foundationUUID) }
                replyHandler(container.map { .usable(name: name, containerID: $0) } ?? .notRecognized, nil)
        }
    }

    func loadResource(
        resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, (any Error)?) -> Void
    ) {
        guard let device = resource as? FSBlockDeviceResource else { return replyHandler(nil, ModuleError.invalid) }
        do throws(DiskError) {
            let fileSystem = try format.open(BlockDeviceSource(device))
            let tree = try MountedTree(fileSystem)
            let volume = ReadOnlyVolume(tree: tree, shortName: format.shortName, log: log, device: device)
            self.volume = volume
            containerStatus = .ready
            log.info("loaded \(device.bsdName, privacy: .public): \(fileSystem.volume.label, privacy: .public)")
            replyHandler(volume, nil)
        } catch {
            log.error("load \(device.bsdName, privacy: .public): \(String(describing: error), privacy: .public)")
            replyHandler(nil, error.fskit)
        }
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping ((any Error)?) -> Void) {
        volume = nil
        replyHandler(nil)
    }
}
