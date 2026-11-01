public import AemiProtobuf
public import MountKit

/// The registry's schema (ADR-0015). Field numbers are never reused; kind and state are plain `int32`, mapped openly by
/// `MountBackendKind(rawValue:)` and `MountRecord.State(rawValue:)`, so a newer version's values are kept, not defaulted.
/// Retired numbers: none yet.
// @dl:accept -- the registry tests mirror this schema on purpose, one field more, to prove a newer version's fields survive
@ProtoMessage public struct RecordMessage {
    @ProtoField(1) public var id: String = ""
    @ProtoField(2) public var kind: Int32 = 0
    @ProtoField(3) public var source: String = ""
    @ProtoField(4) public var mountPoint: String = ""
    @ProtoField(5) public var mountedFrom: String = ""
    @ProtoField(6) public var state: Int32 = 0
}

extension RecordMessage {
    /// The message for `record`, carrying `unknownFields` a newer version wrote.
    public init(_ record: MountRecord, unknownFields: UnknownFields = UnknownFields()) {
        self.init(
            id: record.id,
            kind: record.kind.rawValue,
            source: record.source,
            mountPoint: record.mountPoint,
            mountedFrom: record.mountedFrom,
            state: record.state.rawValue,
            unknownFields: unknownFields
        )
    }

    /// The record, kinds and states mapped openly.
    public var record: MountRecord {
        MountRecord(
            id: id,
            kind: MountBackendKind(rawValue: kind),
            source: source,
            mountPoint: mountPoint,
            mountedFrom: mountedFrom,
            state: MountRecord.State(rawValue: state)
        )
    }
}
