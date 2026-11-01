import AemiProtobuf

/// The registry's schema (ADR-0015). Field numbers are never reused; kind and state are plain `int32`, mapped openly by
/// `MountBackendKind(rawValue:)` and `MountRecord.State(rawValue:)`, so a newer version's values are kept, not defaulted.
/// Retired numbers: none yet.
// @dl:accept -- the registry tests mirror this schema on purpose, one field more, to prove a newer version's fields survive
@ProtoMessage struct RecordMessage {
    @ProtoField(1) var id: String = ""
    @ProtoField(2) var kind: Int32 = 0
    @ProtoField(3) var source: String = ""
    @ProtoField(4) var mountPoint: String = ""
    @ProtoField(5) var mountedFrom: String = ""
    @ProtoField(6) var state: Int32 = 0
}
