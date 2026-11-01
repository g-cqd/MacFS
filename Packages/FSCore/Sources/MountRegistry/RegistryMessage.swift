import AemiProtobuf

/// The registry file's message: its records (ADR-0015). Retired field numbers: none yet.
@ProtoMessage struct RegistryMessage {
    @ProtoField(1) var records: [RecordMessage] = []
}
