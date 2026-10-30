import SwiftUI

/// The Settings window: Status first, since it is what a user opens Settings for.
struct SettingsView: View {
    let status: ExtensionStatus

    var body: some View {
        TabView {
            Tab("Status", systemImage: "checkmark.shield") { StatusPane(status: status) }
            Tab("General", systemImage: "gearshape") { GeneralPane() }
            Tab("Formats", systemImage: "externaldrive") { FormatsPane() }
            Tab("About", systemImage: "info.circle") { AboutPane() }
        }
        .frame(width: 640, height: 460)
    }
}
