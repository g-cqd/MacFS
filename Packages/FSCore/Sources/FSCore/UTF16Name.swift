internal import AemiKernels

/// Decodes UTF-16LE names (NTFS) to UTF-8 bytes.
///
/// Most names are ASCII, which aemi's kernel narrows eight units at a time; the rest goes
/// through the standard library's transcoder, which replaces unpaired surrogates with U+FFFD.
public enum UTF16Name {
    public static func utf8(_ bytes: DiskBytes) -> [UInt8] {
        let units = bytes.count / 2
        let raw = bytes.array
        var ascii = [UInt8](repeating: 0, count: units)
        let narrowed = unsafe BufferPair.withBases(raw, &ascii) { from, to in
            unsafe AemiKernels.asciiPrefix(utf16LE: from, units: units, into: to)
        }
        precondition(narrowed <= units, "asciiPrefix returned more units than it was given")
        if narrowed == units { return ascii }
        var code: [UInt16] = []
        code.reserveCapacity(units)
        for index in 0 ..< units { code.append(UInt16(raw[2 * index]) | UInt16(raw[2 * index + 1]) << 8) }
        return Array(String(decoding: code, as: UTF16.self).utf8)
    }
}
