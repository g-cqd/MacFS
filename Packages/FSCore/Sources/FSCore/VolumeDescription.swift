/// What a volume says about itself.
public struct VolumeDescription: Sendable, Equatable {
    public enum CaseRule: Sendable, Equatable {
        case sensitive
        case insensitivePreserving
    }

    /// Short format name, the one `mount -t` takes: `btrfs`, `ntfs`.
    public var format: String
    public var label: String
    /// 16 bytes.
    public var uuid: [UInt8]
    public var caseRule: CaseRule
    public var maximumNameLength: Int

    public init(format: String, label: String, uuid: [UInt8], caseRule: CaseRule, maximumNameLength: Int) {
        self.format = format
        self.label = label
        self.uuid = uuid
        self.caseRule = caseRule
        self.maximumNameLength = maximumNameLength
    }
}
