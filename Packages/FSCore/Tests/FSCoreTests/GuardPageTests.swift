import AemiTestKit
import CFSKernels
import Testing

/// The NTFS fixups kernel (assembly on arm64) with its record flush against an inaccessible page, at the end and at the start:
/// a read or write beyond the record crashes, which no result comparison could show. aemi tests the kernels FSCore takes from
/// it the same way (its ADR 0021).
@Suite struct GuardPageTests {
    @Test(arguments: GuardedBytes.Edge.allCases)
    func fixupsStayInsideTheRecord(edge: GuardedBytes.Edge) {
        var random = SplitMix(state: 5)
        for (size, stride) in [(512, 512), (1024, 512), (4096, 512), (4096, 4096), (64, 8), (16, 8), (8, 2)] {
            for trial in 0 ..< 40 {
                var record = random.bytes(size)
                let entries = size / stride + 1
                if trial % 5 == 1, size >= 8 {
                    // The right count with the array pushed past the end: only the bounds check refuses it, and a kernel
                    // without one reads (and writes) beyond the record.
                    let offset = (size - 2 * entries + 2 + 1) & ~1
                    record[4] = UInt8(offset & 0xFF)
                    record[5] = UInt8(offset >> 8)
                    record[6] = UInt8(entries & 0xFF)
                    record[7] = UInt8(entries >> 8)
                } else if 8 + 2 * entries <= size, trial % 5 != 0 {
                    // A valid header (array at 8), and on even trials strides that end with the sequence number.
                    record[4] = 8
                    record[5] = 0
                    record[6] = UInt8(entries & 0xFF)
                    record[7] = UInt8(entries >> 8)
                    if trial % 2 == 0 {
                        for index in 1 ..< entries {
                            record[index * stride - 2] = record[8]
                            record[index * stride - 1] = record[9]
                        }
                    }
                }
                var expected = record
                let status = expected.withUnsafeMutableBufferPointer { referenceFixups($0.baseAddress!, size, stride) }
                GuardedBytes.with(record, against: edge) { base in
                    #expect(fsk_ntfs_apply_fixups(base, size, stride) == status, "\(size)/\(stride), trial \(trial)")
                    if status == 0 { #expect(Array(UnsafeBufferPointer(start: base, count: size)) == expected) }
                }
            }
        }
    }

    /// Tokens packed as LZNT1 does: groups of a flag byte (1 for a phrase, low bit first) and eight tokens, under a compressed
    /// chunk's header.
    static func chunk(_ tokens: [(phrase: Bool, bytes: [UInt8])]) -> [UInt8] {
        var data: [UInt8] = []
        for start in stride(from: 0, to: tokens.count, by: 8) {
            let group = tokens[start ..< min(tokens.count, start + 8)]
            data.append(group.enumerated().reduce(UInt8(0)) { $0 | ($1.element.phrase ? 1 << $1.offset : 0) })
            for token in group { data += token.bytes }
        }
        let field = UInt16(data.count - 1) | 0xB000
        return [UInt8(field & 0xFF), UInt8(field >> 8)] + data
    }

    /// A phrase token at `position` in its chunk, split as the position requires.
    static func phrase(at position: Int, distance: Int, length: Int) -> (phrase: Bool, bytes: [UInt8]) {
        var shift = 0
        var reach = position - 1
        while reach >= 0x10 {
            shift += 1
            reach >>= 1
        }
        let token = (distance - 1) << (12 - shift) | (length - 3)
        return (true, [UInt8(token & 0xFF), UInt8(token >> 8)])
    }

    /// A chunk that decodes to exactly 4 KiB: forty literals, then phrases `distance` back, `step` long, the last one
    /// whatever length is left (so chunks end on every kind of tail), or `literals` literals last followed by three phrases
    /// the chunk has no room for (a damaged chunk, whose last literals end at the edge with input still to come).
    static func fullChunk(distance: Int, step: Int, literals: Int = 0) -> [UInt8] {
        var tokens: [(phrase: Bool, bytes: [UInt8])] = (0 ..< 40).map { (false, [UInt8(0x41 + $0)]) }
        var position = 40
        let end = 4096 - literals
        while position < end {
            let remaining = end - position
            let length = remaining > step + 3 ? step : remaining
            if length >= 3 {
                tokens.append(Self.phrase(at: position, distance: distance, length: length))
                position += length
            } else {
                tokens.append((false, [0x5A]))
                position += 1
            }
        }
        if literals > 0 {
            tokens += (0 ..< literals).map { _ in (false, [0x4C]) }
            tokens += (0 ..< 3).map { _ in Self.phrase(at: 4096, distance: 16, length: 3) }
        }
        return Self.chunk(tokens)
    }

    /// The LZNT1 kernel with its input and its output each flush against an inaccessible page: the word copies' overrun must
    /// stop inside the unit, and a stored chunk shorter than 4 KiB must be refused before it is read.
    @Test(arguments: GuardedBytes.Edge.allCases)
    func lznt1StaysInsideItsBuffers(edge: GuardedBytes.Edge) {
        var cases: [([UInt8], Int)] = []
        for distance in [1, 2, 7, 8, 9, 16, 33] {
            for step in [5, 8, 9, 11, 13, 16, 17, 37] {
                let chunk = Self.fullChunk(distance: distance, step: step)
                cases += [(chunk, 4096), (chunk + chunk, 8192)]
            }
        }
        let decodable = cases.count
        for literals in 1 ... 7 { cases.append((Self.fullChunk(distance: 16, step: 13, literals: literals), 4096)) }
        let stored: [UInt8] = [0xFF, 0x3F] + (0 ..< 4096).map { UInt8(truncatingIfNeeded: $0) }
        cases += [(stored, 4096), (Array(stored.prefix(4000)), 4096), (Array(stored.prefix(4000)), 8192)]
        // a stored chunk of 3,999
        let short: [UInt8] = [0x9C, 0x3F] + (0 ..< 3999).map { UInt8(truncatingIfNeeded: $0) }
        cases += [(short, 4096)]
        for (index, (input, capacity)) in cases.enumerated() {
            var expected = [UInt8](repeating: 0, count: capacity)
            let status = input.withUnsafeBufferPointer { source in
                expected.withUnsafeMutableBufferPointer {
                    referenceLZNT1(source.baseAddress!, input.count, $0.baseAddress!, capacity)
                }
            }
            if index < decodable + 7 {
                #expect((status == 0) == (index < decodable), "case \(index): only the damaged chunks should fail")
            }
            GuardedBytes.with(input, against: edge) { source in
                GuardedBytes.with([UInt8](repeating: 0xEE, count: capacity), against: edge) { target in
                    #expect(fsk_lznt1_decompress(source, input.count, target, capacity) == status, "case \(index)")
                    if status == 0 {
                        #expect(Array(UnsafeBufferPointer(start: target, count: capacity)) == expected, "case \(index)")
                    }
                }
            }
        }
    }
}
