import CoreFoundation
import DiskKit
import Foundation
import Testing

/// Disk Arbitration's values, as plain ones: what the watcher hands the model.
struct DiskValueTests {
    @Test func coreFoundationValuesBecomePlainOnes() throws {
        #expect(DiskValue("disk9" as CFString) == "disk9")
        #expect(DiskValue(kCFBooleanTrue) == true)
        #expect(DiskValue(kCFBooleanFalse) == false)
        #expect(DiskValue(NSNumber(value: Int64(133_152_256))) == 133_152_256)
        #expect(DiskValue(URL(fileURLWithPath: "/Volumes/ext4 1") as CFURL) == "/Volumes/ext4 1")
        let uuid = try #require(CFUUIDCreateFromString(nil, "F3CB71FA-598F-44C4-B13F-6CB7CB3A67CA" as CFString))
        #expect(DiskValue(uuid) == "F3CB71FA-598F-44C4-B13F-6CB7CB3A67CA")
    }

    /// Icons and other dictionaries carry nothing the model reads.
    @Test func otherValuesAreLeftOut() {
        #expect(DiskValue([:] as CFDictionary) == nil)
        #expect(DiskValue(Data([1, 2]) as CFData) == nil)
    }
}
