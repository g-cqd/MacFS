public import Formats
public import Foundation

/// The Info.plist of each FSKit module, generated from ``DiskFormat`` so a short name has one source.
public enum ModulePlist {
    public static func directory(for format: DiskFormat) -> String {
        "Extensions/\(format.moduleName)"
    }

    private static func media(_ hint: String, order: Int = 3000) -> [String: Any] {
        ["FSMediaProperties": ["Content Hint": hint, "Leaf": true], "FSProbeOrder": order]
    }

    /// Partition types each format is offered for. A GPT type, an MBR name, and for Linux formats the
    /// whole unpartitioned disk.
    private static func mediaTypes(for format: DiskFormat) -> [String: Any] {
        switch format {
            case .btrfs, .ext:
                [
                    "0FC63DAF-8483-4772-8E79-3D69D8477DE4": media("0FC63DAF-8483-4772-8E79-3D69D8477DE4"),
                    "Linux": media("Linux"),
                    "Partitionless": ["FSMediaProperties": ["Leaf": true, "Whole": true], "FSProbeOrder": 5000]
                ]
            case .ntfs:
                [
                    "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7": media("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"),
                    "Windows_NTFS": media("Windows_NTFS")
                ]
        }
    }

    public static func dictionary(for format: DiskFormat) -> [String: Any] {
        let personality: [String: Any] = [
            "FSName": "\(format.displayName) (read-only)", "FSfileObjectsAreCaseSensitive": format != .ntfs
        ]
        let attributes: [String: Any] = [
            "EXExtensionPointIdentifier": "com.apple.fskit.fsmodule",
            "FSShortName": format.shortName,
            "FSSupportsBlockResources": true,
            "FSSupportsKernelOffloadedIO": true,
            "FSSupportsPathURLs": false,
            "FSSupportsGenericURLResources": false,
            "FSSupportsServerURLs": false,
            "FSRequiresSecurityScopedPathURLResources": false,
            "FSVolumeAlwaysIgnoreOwnership": true,
            "FSActivateOptionSyntax": ["shortOptions": "o:"],
            "FSPersonalities": [format.displayName: personality],
            "FSMediaTypes": mediaTypes(for: format)
        ]
        return [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleDisplayName": format.displayName,
            "CFBundleExecutable": "$(EXECUTABLE_NAME)",
            "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "$(PRODUCT_NAME)",
            "CFBundlePackageType": "$(PRODUCT_BUNDLE_PACKAGE_TYPE)",
            "CFBundleShortVersionString": "$(MARKETING_VERSION)",
            "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
            "EXAppExtensionAttributes": attributes
        ]
    }

    public static func data(for format: DiskFormat) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dictionary(for: format), format: .xml, options: 0)
    }

    /// Whether `existing` differs in content from what ``data(for:)`` generates (formatting aside).
    public static func drifted(existing: Data?, for format: DiskFormat) -> Bool {
        guard let existing,
            let parsed = try? PropertyListSerialization.propertyList(from: existing, format: nil) as? NSDictionary
        else { return true }
        return !parsed.isEqual(to: dictionary(for: format))
    }
}
