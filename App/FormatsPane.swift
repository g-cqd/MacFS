import Formats
import SwiftUI

/// Settings → Formats: what each format's module reads, how to mount it by hand, and what it is held to.
struct FormatsPane: View {
    var body: some View {
        Form {
            ForEach(DiskFormat.allCases, id: \.self) { format in
                Section(format.displayName) {
                    LabeledContent("Mount by hand", value: "mount -F -t \(format.shortName) -o rdonly /dev/diskN dir")
                        .textSelection(.enabled)
                    LabeledContent("Module", value: format.moduleBundleIdentifier).textSelection(.enabled)
                    Text(Self.summary(format)).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// docs/conformance, in a sentence each.
    static func summary(_ format: DiskFormat) -> String {
        switch format {
            case .btrfs:
                "Plain, zlib and LZO extents, CRC-32C and xxHash checksums, subvolumes. Checked against btrfs-progs and its test suite."
            case .ntfs:
                "Resident, non-resident and sparse streams, reparse and Interix links. Checked against ntfs-3g."
            case .ext:
                "ext2, ext3 and ext4: extents, inline data, bigalloc, metadata checksums. Checked against the Linux kernel and e2fsprogs."
        }
    }
}
