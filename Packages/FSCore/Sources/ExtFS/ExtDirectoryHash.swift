/// ext's directory hashes, as Linux's `ext4fs_dirhash` (fs/ext4/hash.c) computes them for htree lookup (roadmap 0016).
/// Versions 0 to 2 are the legacy hash, half-MD4 and TEA over bytes read as signed `char`; 3 to 5 are the same over unsigned
/// bytes. SipHash (6) needs casefolding and encryption, which this reader does not follow. The seed is `s_hash_seed`, or
/// MD4's initial words when it is all zero. The major hash's low bit is cleared: the index uses it to mark collisions.
enum ExtDirectoryHash {
    static func hash(_ name: [UInt8], version: UInt8, seed: [UInt32]) -> (major: UInt32, minor: UInt32)? {
        guard version <= 5 else { return nil }
        var buffer = SIMD4<UInt32>(0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476)
        if seed.count == 4, seed.contains(where: { $0 != 0 }) { buffer = SIMD4(seed) }
        let signed = version < 3
        var major: UInt32
        var minor: UInt32 = 0
        if version % 3 == 0 {
            major = legacy(name, signed: signed)
        } else {
            // Half-MD4 takes 32 bytes at a time, TEA 16, while any remain (`while (len > 0)`).
            let isMD4 = version % 3 == 1
            let chunk = isMD4 ? 32 : 16
            for start in stride(from: 0, to: name.count, by: chunk) {
                let words = Self.words(name[start...], count: chunk / 4, signed: signed)
                if isMD4 { halfMD4(&buffer, words) } else { tea(&buffer, words) }
            }
            (major, minor) = isMD4 ? (buffer[1], buffer[2]) : (buffer[0], buffer[1])
        }
        major &= ~1
        // 0x7FFFFFFF << 1 is the end-of-directory position, never a name's hash.
        if major == 0xFFFF_FFFE { major = 0xFFFF_FFFC }
        return (major, minor)
    }

    /// A byte as `char` would widen it to `int`: sign-extended when `char` is signed.
    private static func widened(_ byte: UInt8, signed: Bool) -> UInt32 {
        signed ? UInt32(bitPattern: Int32(Int8(bitPattern: byte))) : UInt32(byte)
    }

    /// `dx_hack_hash`: the original ext3 hash.
    private static func legacy(_ name: [UInt8], signed: Bool) -> UInt32 {
        var (hash0, hash1): (UInt32, UInt32) = (0x12A3_FE2D, 0x37AB_E8F9)
        for byte in name {
            var hash = hash1 &+ (hash0 ^ (widened(byte, signed: signed) &* 7_152_373))
            if hash & 0x8000_0000 != 0 { hash &-= 0x7FFF_FFFF }
            (hash1, hash0) = (hash0, hash)
        }
        return hash0 << 1
    }

    /// `str2hashbuf`: up to `4 * count` bytes packed big-end first into `count` words, the rest filled with the length.
    private static func words(_ bytes: ArraySlice<UInt8>, count: Int, signed: Bool) -> [UInt32] {
        var pad = UInt32(truncatingIfNeeded: bytes.count) | UInt32(truncatingIfNeeded: bytes.count) << 8
        pad |= pad << 16
        var words: [UInt32] = []
        words.reserveCapacity(count)
        var value = pad
        for (index, byte) in bytes.prefix(4 * count).enumerated() {
            value = widened(byte, signed: signed) &+ (value << 8)
            if index % 4 == 3 {
                words.append(value)
                value = pad
            }
        }
        if words.count < count { words.append(value) }
        while words.count < count { words.append(pad) }
        return words
    }

    private static func tea(_ buffer: inout SIMD4<UInt32>, _ input: [UInt32]) {
        var sum: UInt32 = 0
        var (b0, b1) = (buffer[0], buffer[1])
        for _ in 0 ..< 16 {
            sum &+= 0x9E37_79B9
            b0 &+= ((b1 << 4) &+ input[0]) ^ (b1 &+ sum) ^ ((b1 >> 5) &+ input[1])
            b1 &+= ((b0 << 4) &+ input[2]) ^ (b0 &+ sum) ^ ((b0 >> 5) &+ input[3])
        }
        buffer[0] &+= b0
        buffer[1] &+= b1
    }

    /// Half-MD4's three rounds: the order each takes the eight words in, its constant (MD4's K2 and K3) and its four shifts.
    private static let orders = [[0, 1, 2, 3, 4, 5, 6, 7], [1, 3, 5, 7, 0, 2, 4, 6], [3, 7, 2, 6, 1, 5, 0, 4]]
    private static let constants: [UInt32] = [0, 0x5A82_7999, 0x6ED9_EBA1]
    private static let shifts: [[UInt32]] = [[3, 7, 11, 19], [3, 5, 9, 13], [3, 9, 11, 15]]

    /// MD4's selection, majority and parity functions, one per round.
    private static func mix(_ round: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        switch round {
            case 0: z ^ (x & (y ^ z))
            case 1: (x & y) &+ ((x ^ y) & z)
            default: x ^ y ^ z
        }
    }

    /// MD4's three rounds, halved: eight words in, the buffer updated. The roles of a, b, c and d rotate one place per step.
    private static func halfMD4(_ buffer: inout SIMD4<UInt32>, _ words: [UInt32]) {
        var state = buffer
        for round in 0 ..< 3 {
            for (step, word) in orders[round].enumerated() {
                let a = (4 - step % 4) % 4
                let mixed = mix(round, state[(a + 1) % 4], state[(a + 2) % 4], state[(a + 3) % 4])
                let sum = state[a] &+ mixed &+ words[word] &+ constants[round]
                let shift = shifts[round][step % 4]
                state[a] = sum << shift | sum >> (32 - shift)
            }
        }
        buffer &+= state
    }
}
