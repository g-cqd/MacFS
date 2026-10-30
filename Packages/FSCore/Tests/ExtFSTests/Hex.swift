/// Bytes from the hex the reference tools print (names and seeds in TestImages/dxhash.txt and xfshash.txt). Shared by the
/// ext and XFS tests (a link in XFSTests).
enum Hex {
    static func bytes(_ hex: String) -> [UInt8] {
        let digits = Array(hex.utf8)
        return stride(from: 0, to: digits.count, by: 2)
            .map { UInt8(String(decoding: digits[$0 ..< $0 + 2], as: UTF8.self), radix: 16) ?? 0 }
    }
}
