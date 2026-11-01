import FSCore

/// An independent LZO1X decoder for the differential test, written from the format's description (the instruction table in
/// liblzo's `lzo1x_d.ch` and Linux's `Documentation/staging/lzo.rst`) rather than from `LZO1X`: an array that grows one byte at
/// a time, and each instruction decoded into (match length, distance, trailing literals) before anything is copied. Slow on
/// purpose; it agrees with liblzo2 on every fixture (`LZO1XTests`).
enum LZO1XReference {
    private struct Instruction {
        var length: Int
        var distance: Int
        var trailing: Int
        var isEnd = false
    }

    static func decompress(_ stream: [UInt8], capacity: Int) throws(DiskError) -> [UInt8] {
        var out: [UInt8] = []
        var index = 0
        func byte() throws(DiskError) -> Int {
            guard index < stream.count else { throw .corrupt("reference: truncated") }
            index += 1
            return Int(stream[index - 1])
        }
        func length(_ bits: Int, _ mask: Int) throws(DiskError) -> Int {
            var value = bits & mask
            guard value == 0 else { return value }
            value = mask
            while true {
                guard index < stream.count else { throw .corrupt("reference: truncated length") }
                if stream[index] != 0 { break }
                index += 1
                value += 255
                guard value < 1 << 24 else { throw .corrupt("reference: length overflow") }
            }
            return value + (try byte())
        }
        func copyLiterals(_ count: Int) throws(DiskError) {
            guard count <= capacity - out.count else { throw .corrupt("reference: output overrun") }
            guard count <= stream.count - index else { throw .corrupt("reference: input overrun") }
            out.append(contentsOf: stream[index ..< index + count])
            index += count
        }
        func copyMatch(_ instruction: Instruction) throws(DiskError) {
            guard instruction.distance >= 1, instruction.distance <= out.count else {
                throw .corrupt("reference: distance")
            }
            guard instruction.length <= capacity - out.count else { throw .corrupt("reference: output overrun") }
            for _ in 0 ..< instruction.length { out.append(out[out.count - instruction.distance]) }
        }

        var previous = 0  // literals copied by the last instruction: 0, 1 to 3, or 4 for a long run
        var code = try byte()
        if code > 17 {
            try copyLiterals(code - 17)
            previous = code - 17 < 4 ? code - 17 : 4
            code = try byte()
        }
        while true {
            let instruction: Instruction
            switch code {
                case 64 ... 255:  // M2: 3 to 8 bytes, distance up to 2 KiB
                    let next = try byte()
                    instruction = Instruction(
                        length: (code >> 5) + 1,
                        distance: ((code >> 2) & 7) + next * 8 + 1,
                        trailing: code & 3
                    )
                case 32 ... 63:  // M3: distance up to 16 KiB
                    let count = try length(code, 31) + 2
                    let low = try byte()
                    let high = try byte()
                    instruction = Instruction(length: count, distance: ((low | high << 8) >> 2) + 1, trailing: low & 3)
                case 16 ... 31:  // M4: distance 16 KiB to 48 KiB, or the end
                    let count = try length(code, 7) + 2
                    let low = try byte()
                    let high = try byte()
                    let far = (code & 8) << 11 | (low | high << 8) >> 2
                    instruction = Instruction(length: count, distance: far + 0x4000, trailing: low & 3, isEnd: far == 0)
                case _ where previous == 0:  // a literal run of 4 or more
                    try copyLiterals(try length(code, 15) + 3)
                    previous = 4
                    code = try byte()
                    continue
                default:  // M1: 2 bytes after short literals, 3 bytes after a long run
                    let next = try byte()
                    instruction =
                        previous == 4
                        ? Instruction(length: 3, distance: (code >> 2) + next * 4 + 0x801, trailing: code & 3)
                        : Instruction(length: 2, distance: (code >> 2) + next * 4 + 1, trailing: code & 3)
            }
            if instruction.isEnd { break }
            try copyMatch(instruction)
            try copyLiterals(instruction.trailing)
            previous = instruction.trailing
            code = try byte()
        }
        return out
    }
}
