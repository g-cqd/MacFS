import FSCore

/// LZO1X decompression, bounds-checked at every step (after the Linux `lzo1x_decompress_safe`).
///
/// Every length and distance comes from the disk, so each copy checks the input it reads, the output it may still write
/// (`capacity`) and how far back a match may reach. Loops are bounded by the input: each iteration consumes at least one byte.
///
/// Bytes move in words where the room allows (diary 2026-10-30-11): a match at least eight bytes back copies eight bytes at a
/// time front to back, so each word reads only bytes already final; a short literal run copies one word when eight bytes of
/// input and output remain. Tests compare it with liblzo2's output and, on mutated streams, with the byte-wise decoder.
enum LZO1X {
    static func decompress(_ input: [UInt8], capacity: Int) throws(DiskError) -> [UInt8] {
        guard capacity >= 0 else { throw .corrupt("lzo: capacity \(capacity)") }
        var output = [UInt8](repeating: 0, count: capacity)
        var failure: DiskError?
        let written = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target -> Int in
                do throws(DiskError) { return try unsafe decompress(source, into: target) } catch {
                    failure = error
                    return 0
                }
            }
        }
        if let failure { throw failure }
        return written == capacity ? output : Array(output[0 ..< written])
    }

    /// Decodes `input` into `output` (at most `output.count` bytes) and returns how many were written. For the Btrfs framing,
    /// which decodes every sector's segment in place into one extent.
    @unsafe static func decompress(_ input: UnsafeBufferPointer<UInt8>, into output: UnsafeMutableBufferPointer<UInt8>)
        throws(DiskError) -> Int
    {
        var machine = unsafe Machine(input, output)
        try machine.run()
        return machine.written
    }

    /// The decoder's state over the input and the output for one call. `@safe`: both buffers belong to arrays for the length
    /// of their `with…BufferPointer` calls, and every access below is preceded by a check against `inputCount` or `capacity`.
    @safe private struct Machine {
        let input: UnsafePointer<UInt8>?
        let inputCount: Int
        let output: UnsafeMutablePointer<UInt8>?
        let capacity: Int
        var position = 0
        var written = 0

        init(_ input: UnsafeBufferPointer<UInt8>, _ output: UnsafeMutableBufferPointer<UInt8>) {
            unsafe self.input = input.baseAddress
            inputCount = input.count
            unsafe self.output = output.baseAddress
            capacity = output.count
        }

        @inline(__always) mutating func next() throws(DiskError) -> Int {
            guard position < inputCount, let input = unsafe input else {
                throw .corrupt("lzo: input ends inside an instruction")
            }
            let byte = unsafe input[position]
            position += 1
            return Int(byte)
        }

        @inline(__always) mutating func le16() throws(DiskError) -> Int {
            let low = try next()
            return low | (try next() << 8)
        }

        /// A length continued by zero bytes, each worth 255, then one non-zero byte.
        mutating func extended(_ base: Int) throws(DiskError) -> Int {
            var total = base
            while true {
                guard position < inputCount, let input = unsafe input else {
                    throw .corrupt("lzo: input ends inside a run length")
                }
                guard unsafe input[position] == 0 else { break }
                position += 1
                total += 255
                guard total < 1 << 24 else { throw .corrupt("lzo: run length overflow") }
            }
            return total + (try next())
        }

        @inline(__always) mutating func literals(_ count: Int) throws(DiskError) {
            guard count <= capacity - written else { throw .corrupt("lzo: output overrun") }
            guard count <= inputCount - position else { throw .corrupt("lzo: input overrun") }
            guard count > 0, let to = unsafe output, let from = unsafe input else { return }
            if count <= 8, inputCount - position >= 8, capacity - written >= 8 {
                // One word: the bytes past `count` are rewritten later or lie past the result's end.
                unsafe (to + written)
                    .withMemoryRebound(to: UInt8.self, capacity: 8) { target in
                        unsafe UnsafeMutableRawPointer(target)
                            .storeBytes(
                                of: UnsafeRawPointer(from + position).loadUnaligned(as: UInt64.self), as: UInt64.self)
                    }
            } else {
                unsafe (to + written).update(from: from + position, count: count)
            }
            written += count
            position += count
        }

        @inline(__always) mutating func match(distance: Int, count: Int) throws(DiskError) {
            guard distance >= 1, distance <= written else { throw .corrupt("lzo: match before the start") }
            guard count <= capacity - written, let to = unsafe output else { throw .corrupt("lzo: output overrun") }
            var from = written - distance
            var at = written
            let end = written + count
            if distance >= 8 {
                // Words front to back: each reads bytes at least eight behind it, all final. The last word may run past `end`
                // but never past `capacity`.
                while at < end, capacity - at >= 8 {
                    let word = unsafe UnsafeRawPointer(to + from).loadUnaligned(as: UInt64.self)
                    unsafe UnsafeMutableRawPointer(to + at).storeBytes(of: word, as: UInt64.self)
                    at += 8
                    from += 8
                }
            }
            while at < end {
                unsafe to[at] = unsafe to[from]
                at += 1
                from += 1
            }
            written = end
        }

        mutating func run() throws(DiskError) {
            var state = 0
            var first = try next()
            if first > 17 {
                let count = first - 17
                try literals(count)
                state = count < 4 ? count : 4
                first = try next()
            }
            var instruction = first
            while true {
                var following = 0
                if instruction < 16 {
                    if state == 0 {
                        var count = instruction
                        if count == 0 { count = try extended(15) }
                        try literals(count + 3)
                        state = 4
                        instruction = try next()
                        continue
                    }
                    following = instruction & 3
                    let low = try next()
                    if state != 4 {
                        try match(distance: 1 + (instruction >> 2) + (low << 2), count: 2)
                    } else {
                        try match(distance: 1 + 0x0800 + (instruction >> 2) + (low << 2), count: 3)
                    }
                } else if instruction >= 64 {
                    following = instruction & 3
                    let low = try next()
                    try match(distance: 1 + ((instruction >> 2) & 7) + (low << 3), count: (instruction >> 5) + 1)
                } else if instruction >= 32 {
                    var count = instruction & 31
                    if count == 0 { count = try extended(31) }
                    let word = try le16()
                    following = word & 3
                    try match(distance: 1 + (word >> 2), count: count + 2)
                } else {
                    var count = instruction & 7
                    if count == 0 { count = try extended(7) }
                    let word = try le16()
                    following = word & 3
                    let distance = ((instruction & 8) << 11) + (word >> 2)
                    if distance == 0 { break }  // end-of-stream marker
                    try match(distance: distance + 0x4000, count: count + 2)
                }
                state = following
                try literals(following)
                instruction = try next()
            }
        }
    }
}
