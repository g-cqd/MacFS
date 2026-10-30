import SwiftUI

/// Settings → About.
struct AboutPane: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 64, height: 64)
            Text("MacFS").font(.title.weight(.semibold))
            Text("Version \(Self.version)").foregroundStyle(.secondary)
            Text(
                "Btrfs, NTFS and ext2/3/4 volumes on macOS, read-only, through FSKit, an NFS proxy, or the browser in this app."
            )
            .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary).frame(maxWidth: 380)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
