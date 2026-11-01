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
}
