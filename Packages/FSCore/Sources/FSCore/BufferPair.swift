/// The two-buffer shape of every kernel and decoder that reads one array and writes into another, preallocated: both base
/// addresses, or nothing when either array is empty.
public enum BufferPair {
    /// `body` with the base addresses of `source` and `target`; 0 without calling it when either is empty.
    public static func withBases(
        _ source: [UInt8], _ target: inout [UInt8],
        _ body: (UnsafePointer<UInt8>, UnsafeMutablePointer<UInt8>) -> Int
    ) -> Int {
        source.withUnsafeBufferPointer { from in
            target.withUnsafeMutableBufferPointer { into in
                guard let fromBase = from.baseAddress, let intoBase = into.baseAddress else { return 0 }
                return unsafe body(fromBase, intoBase)
            }
        }
    }
}
