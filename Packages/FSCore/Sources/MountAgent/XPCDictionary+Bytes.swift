import XPC

@available(macOS 27, *)
extension XPCDictionary {
    /// Stores `bytes` under `key` through the C API. Assigning a `RawSpan` through the Swift subscript crashes the compiler
    /// (Swift 6.4, SILGen; reduced to one line in docs/diary/2026-11-01-04.md).
    func setBytes(_ bytes: [UInt8], for key: String) {
        withUnsafeUnderlyingDictionary { object in
            bytes.withUnsafeBytes { raw in
                let empty: UInt8 = 0
                if let base = raw.baseAddress {
                    unsafe xpc_dictionary_set_data(object, key, base, raw.count)
                } else {
                    withUnsafePointer(to: empty) { unsafe xpc_dictionary_set_data(object, key, $0, 0) }
                }
            }
        }
    }

    /// The bytes stored under `key`, or nil when there is no data value there. The Swift subscript reads an empty data value
    /// as absent, and an empty protobuf message is empty: an empty listing came back as "no bytes".
    func bytes(for key: String) -> [UInt8]? {
        withUnsafeUnderlyingDictionary { object -> [UInt8]? in
            guard let value = unsafe xpc_dictionary_get_value(object, key), xpc_get_type(value) == XPC_TYPE_DATA else {
                return nil
            }
            let count = xpc_data_get_length(value)
            guard count > 0, let base = unsafe xpc_data_get_bytes_ptr(value) else { return [] }
            return unsafe Array(UnsafeRawBufferPointer(start: base, count: count))
        }
    }
}
