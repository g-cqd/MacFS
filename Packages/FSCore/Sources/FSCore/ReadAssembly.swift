/// The result of a file read, built in place (docs/conformance/performance.md): pieces read from the source straight into it,
/// one copy as the kernel's own `read`, decoded bytes copied in, and every byte between and after the pieces zero. Pieces come
/// in ascending order without overlap, so no byte of the result is left unwritten.
public enum ReadAssembly {
    /// `@safe`: the buffer is reached only through `read` and `copy`, which check every range against it.
    @safe public struct Pieces: ~Copyable {
        private let buffer: UnsafeMutableRawBufferPointer
        private let size: Int
        /// Everything before this position is written.
        private var cursor = 0

        fileprivate init(_ buffer: UnsafeMutableRawBufferPointer) {
            unsafe self.buffer = buffer
            size = buffer.count
        }

        private func zero(_ range: Range<Int>) {
            unsafe UnsafeMutableRawBufferPointer(rebasing: buffer[range]).initializeMemory(as: UInt8.self, repeating: 0)
        }

        /// The region `position ..< position + count`, after zeroing the gap before it.
        private mutating func claim(_ position: Int, _ count: Int) throws(DiskError) -> UnsafeMutableRawBufferPointer {
            guard position >= cursor, count >= 0, position <= size - count else {
                throw .corrupt("a piece of \(count) bytes at \(position) after \(cursor) in a \(size)-byte read")
            }
            if position > cursor { zero(cursor ..< position) }
            cursor = position + count
            return unsafe UnsafeMutableRawBufferPointer(rebasing: buffer[position ..< position + count])
        }

        /// `count` bytes of `source` at `offset`, read straight into the result at `position`.
        public mutating func read(_ source: any BlockSource, at offset: UInt64, to position: Int, count: Int)
            throws(DiskError)
        {
            let region = unsafe try claim(position, count)
            try unsafe source.read(at: offset, into: region)
        }

        /// The same, then `inspect` sees the bytes where they landed (a checksum over the result, without reading twice).
        public mutating func read(
            _ source: any BlockSource,
            at offset: UInt64,
            to position: Int,
            count: Int,
            inspect: (UnsafeRawBufferPointer) throws(DiskError) -> Void
        ) throws(DiskError) {
            let region = unsafe try claim(position, count)
            try unsafe source.read(at: offset, into: region)
            try unsafe inspect(UnsafeRawBufferPointer(region))
        }

        /// Bytes already in memory (decoded, inline), copied in at `position` with one `memcpy`. Concrete, not generic: from
        /// another module a generic copy is not specialized and went element by element (34 MB/s on zlib extents).
        public mutating func copy(_ bytes: ArraySlice<UInt8>, to position: Int) throws(DiskError) {
            let region = unsafe try claim(position, bytes.count)
            bytes.withUnsafeBytes { unsafe region.copyMemory(from: $0) }
        }

        /// `count` bytes at `position` written by `decode` in place (a decoder writing straight into the result, roadmap 0014);
        /// `decode` must write all of them.
        public mutating func fill(
            to position: Int,
            count: Int,
            _ decode: (UnsafeMutableRawBufferPointer) throws(DiskError) -> Void
        ) throws(DiskError) {
            let region = unsafe try claim(position, count)
            try unsafe decode(region)
        }

        public mutating func copy(_ bytes: [UInt8], to position: Int) throws(DiskError) {
            try copy(bytes[...], to: position)
        }

        fileprivate mutating func finish() {
            if cursor < size { zero(cursor ..< size) }
            cursor = size
        }
    }

    public static func assemble(count: Int, _ fill: (inout Pieces) throws(DiskError) -> Void) throws(DiskError)
        -> [UInt8]
    {
        guard count > 0 else { return [] }
        var failure: DiskError?
        let result = unsafe [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
            var pieces = unsafe Pieces(UnsafeMutableRawBufferPointer(buffer))
            do throws(DiskError) { try fill(&pieces) } catch { failure = error }
            pieces.finish()
            initialized = count
        }
        if let failure { throw failure }
        return result
    }
}
