import SwiftUI

@main
struct MacFSApp: App {
    @State private var status = ExtensionStatus()

    var body: some Scene {
        WindowGroup("MacFS") {
            ContentView(status: status)
                .frame(minWidth: 720, minHeight: 460)
        }
        Settings {
            SettingsView(status: status)
        }
    }
}
