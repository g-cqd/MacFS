import FSCore

/// LZO1X decompression, bounds-checked at every step (after the Linux `lzo1x_decompress_safe`).
///
/// Every length and distance comes from the disk, so each copy checks the input it reads, the output
/// it may still write (`capacity`) and how far back a match may reach. Loops are bounded by the input:
/// each iteration consumes at least one byte.
enum LZO1X {
    private struct Input {
        let bytes: [UInt8]
        var position = 0

        mutating func next() throws(DiskError) -> Int {
            guard position < bytes.count else { throw .corrupt("lzo: input ends inside an instruction") }
            defer { position += 1 }
            return Int(bytes[position])
        }

        mutating func le16() throws(DiskError) -> Int {
            let low = try next()
            return low | (try next() << 8)
        }

        /// A length continued by zero bytes, each worth 255, then one non-zero byte.
        mutating func extended(_ base: Int) throws(DiskError) -> Int {
            var total = base
            while try peekIsZero() {
                position += 1
                total += 255
                guard total < 1 << 24 else { throw .corrupt("lzo: run length overflow") }
            }
            return total + (try next())
        }

        private func peekIsZero() throws(DiskError) -> Bool {
            guard position < bytes.count else { throw .corrupt("lzo: input ends inside a run length") }
            return bytes[position] == 0
        }
    }

    static func decompress(_ input: [UInt8], capacity: Int) throws(DiskError) -> [UInt8] {
        // Written in place: the output size is known, and growing an array byte by byte was the decoder's cost
        // (roadmap 0012). The decoding runs inside one buffer scope so a write is a store, not a uniqueness check.
        var output = [UInt8](repeating: 0, count: capacity)
        var failure: DiskError?
        let written = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { buffer -> Int in
                var sink = unsafe Sink(buffer: buffer, input: source, capacity: capacity)
                do throws(DiskError) {
                    try decode(input, into: &sink)
                } catch {
                    failure = error
                }
                return sink.written
            }
        }
        if let failure { throw failure }
        return written == capacity ? output : Array(output[0 ..< written])
    }

    /// The output: every write is checked against `capacity` before it is made. `@safe`: the buffer is the
    /// array's own storage for the length of one `withUnsafeMutableBufferPointer` call, and no index reaches it
    /// unchecked.
    @safe private struct Sink {
        let buffer: UnsafeMutableBufferPointer<UInt8>
        let input: UnsafeBufferPointer<UInt8>
        let capacity: Int
        var written = 0

        mutating func literals(_ source: inout Input, _ count: Int) throws(DiskError) {
            guard count <= capacity - written else { throw .corrupt("lzo: output overrun") }
            let inputCount = unsafe input.count
            guard count <= inputCount - source.position else { throw .corrupt("lzo: input overrun") }
            if count > 0, let to = unsafe buffer.baseAddress, let from = unsafe input.baseAddress {
                unsafe (to + written).update(from: from + source.position, count: count)
            }
            written += count
            source.position += count
        }

        /// Copies `count` bytes from `distance` back, byte by byte: a match may overlap what it writes. A NEON copy
        /// measured no faster on LZO's short matches (roadmap 0012).
        mutating func match(distance: Int, count: Int) throws(DiskError) {
            guard distance >= 1, distance <= written else { throw .corrupt("lzo: match before the start") }
            guard count <= capacity - written else { throw .corrupt("lzo: output overrun") }
            let from = written - distance
            for index in 0 ..< count { unsafe buffer[written + index] = unsafe buffer[from + index] }
            written += count
        }
    }

    private static func decode(_ input: [UInt8], into sink: inout Sink) throws(DiskError) {
        var source = Input(bytes: input)
        func literals(_ count: Int, _ source: inout Input) throws(DiskError) { try sink.literals(&source, count) }
        func match(distance: Int, count: Int) throws(DiskError) { try sink.match(distance: distance, count: count) }

        var state = 0
        var first = try source.next()
        if first > 17 {
            let count = first - 17
            try literals(count, &source)
            state = count < 4 ? count : 4
            first = try source.next()
        }
        var instruction = first
        while true {
            var next = 0
            if instruction < 16 {
                if state == 0 {
                    var count = instruction
                    if count == 0 { count = try source.extended(15) }
                    try literals(count + 3, &source)
                    state = 4
                    instruction = try source.next()
                    continue
                }
                next = instruction & 3
                let low = try source.next()
                if state != 4 {
                    try match(distance: 1 + (instruction >> 2) + (low << 2), count: 2)
                } else {
                    try match(distance: 1 + 0x0800 + (instruction >> 2) + (low << 2), count: 3)
                }
            } else if instruction >= 64 {
                next = instruction & 3
                let low = try source.next()
                try match(distance: 1 + ((instruction >> 2) & 7) + (low << 3), count: (instruction >> 5) + 1)
            } else if instruction >= 32 {
                var count = instruction & 31
                if count == 0 { count = try source.extended(31) }
                let word = try source.le16()
                next = word & 3
                try match(distance: 1 + (word >> 2), count: count + 2)
            } else {
                var count = instruction & 7
                if count == 0 { count = try source.extended(7) }
                let word = try source.le16()
                next = word & 3
                let distance = ((instruction & 8) << 11) + (word >> 2)
                if distance == 0 { break }  // end-of-stream marker
                try match(distance: distance + 0x4000, count: count + 2)
            }
            state = next
            try literals(next, &source)
            instruction = try source.next()
        }
    }
}
