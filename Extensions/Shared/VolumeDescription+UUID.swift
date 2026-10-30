import FSCore
import Foundation

extension VolumeDescription {
    /// The volume's 16 identifier bytes as a `UUID`, zero-padded (NTFS has only an 8-byte serial).
    var foundationUUID: UUID {
        let b = uuid + [UInt8](repeating: 0, count: max(0, 16 - uuid.count))
        return UUID(
            uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
        )
    }
}
