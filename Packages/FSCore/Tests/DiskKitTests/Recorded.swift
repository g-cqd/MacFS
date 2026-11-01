import AemiJSON
import DiskKit
import Foundation

/// Disk Arbitration descriptions recorded from the test images, attached with and without mounting (macOS 27, MacFS's four
/// modules installed; exFAT and APFS made with `hdiutil create`; `linux-blank` is `ext4-gpt` with its superblock zeroed), in
/// `Recorded.json`. Keyed "<image> <nomount|mounted> <BSD name>"; the APFS image's physical disk is "apfs nomount physical
/// <BSD name>" (its container is the synthesized disk10). Recorded by docs/research/probes/disk-description-recorder.swift.txt.
enum Recorded {
    static let descriptions: [String: [String: DiskValue]] = {
        guard
            let url = Bundle.module.url(forResource: "Recorded", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let decoded = try? AemiJSON.JSONDecoder().decode([String: [String: DiskValue]].self, from: data)
        else { return [:] }
        return decoded
    }()

    static subscript(_ key: String) -> [String: DiskValue] { descriptions[key] ?? [:] }
}

/// A recorded value is a JSON string, number or boolean.
extension DiskValue: Decodable {
    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let flag = try? value.decode(Bool.self) {
            self = .flag(flag)
        } else if let number = try? value.decode(Int64.self) {
            self = .number(number)
        } else {
            self = .text(try value.decode(String.self))
        }
    }
}
