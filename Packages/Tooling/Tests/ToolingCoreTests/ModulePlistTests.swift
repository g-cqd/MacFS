import Formats
import Foundation
import Testing
import ToolingCore

@Suite struct ModulePlistTests {
    @Test(arguments: DiskFormat.allCases)
    func theShortNameComesFromDiskFormat(_ format: DiskFormat) throws {
        let plist = ModulePlist.dictionary(for: format)
        let attributes = try #require(plist["EXAppExtensionAttributes"] as? [String: Any])
        #expect(attributes["FSShortName"] as? String == format.shortName)
        #expect(attributes["EXExtensionPointIdentifier"] as? String == "com.apple.fskit.fsmodule")
        #expect(attributes["FSSupportsBlockResources"] as? Bool == true)
        // The kernel reads mapped files itself (roadmap 0018), as Apple's msdos module declares.
        #expect(attributes["FSSupportsKernelOffloadedIO"] as? Bool == true)
        #expect((attributes["FSMediaTypes"] as? [String: Any])?.isEmpty == false)
    }

    @Test func eachFormatHasItsOwnModuleDirectory() {
        let directories = DiskFormat.allCases.map(ModulePlist.directory(for:))
        #expect(Set(directories).count == DiskFormat.allCases.count)
    }

    @Test func driftIsReported() throws {
        let generated = try ModulePlist.data(for: .btrfs)
        #expect(ModulePlist.drifted(existing: generated, for: .btrfs) == false)
        #expect(ModulePlist.drifted(existing: Data("<plist/>".utf8), for: .btrfs) == true)
        #expect(ModulePlist.drifted(existing: nil, for: .btrfs) == true)
    }
}
