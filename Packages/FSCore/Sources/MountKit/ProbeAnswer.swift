public import FSCore

/// What a module answers when the system asks whether it can mount a disk.
///
/// A volume the reader opens is `usable`, read-only as it is: Disk Arbitration treats `usableButLimited`
/// as a failed probe (status 0xFFFFFFFA in its log) and never mounts the disk (ADR-0009). The read-only
/// limit is carried by the mount options instead (`requestedMountOptions = .readOnly`).
public enum ProbeAnswer: Equatable, Sendable {
    case notRecognized
    case usable(name: String)

    public init(_ volume: VolumeDescription?) {
        guard let volume else {
            self = .notRecognized
            return
        }
        self = .usable(name: volume.label.isEmpty ? volume.format : volume.label)
    }
}
